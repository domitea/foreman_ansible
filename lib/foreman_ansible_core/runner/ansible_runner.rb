module ForemanAnsibleCore
  module Runner
    class AnsibleRunner < ForemanTasksCore::Runner::Parent
      include ForemanTasksCore::Runner::Command

      def initialize(input, suspended_action:)
        super input, :suspended_action => suspended_action
        @inventory = rebuild_secrets(rebuild_inventory(input), input)
        @playbook = input.values.first[:input][:action_input][:script]
        @root = working_dir
      end

      def start
        prepare_directory_structure
        write_inventory
        write_playbook
        start_ansible_runner
      end

      def refresh
        return unless super
        @counter ||= 1
        @uuid ||= File.basename(Dir["#{@root}/artifacts/*"].first)
        job_event_dir = File.join(@root, 'artifacts', @uuid, 'job_events')
        loop do
          files = Dir["#{job_event_dir}/*.json"].map do |file|
            num = File.basename(file)[/\A\d+/].to_i unless file.include?('partial')
            [file, num]
          end
          files_with_nums = files.select { |(_, num)| num && num >= @counter }.sort_by(&:last)
          break if files_with_nums.empty?
          logger.debug("[foreman_ansible] - processing event files: #{files_with_nums.map(&:first).inspect}}")
          files_with_nums.map(&:first).each { |event_file| handle_event_file(event_file) }
          @counter = files_with_nums.last.last + 1
        end
      end

      private

      def handle_event_file(event_file)
        logger.debug("[foreman_ansible] - parsing event file #{event_file}")
        begin
          event = JSON.parse(File.read(event_file))
          if (hostname = event.dig('event_data', 'host'))
            handle_host_event(hostname, event)
          else
            handle_broadcast_data(event)
          end
          true
        rescue JSON::ParserError => e
          logger.error("[foreman_ansible] - Error parsing runner event at #{event_file}: #{e.class}: #{e.message}")
          logger.debug(e.backtrace.join("\n"))
        end
      end

      def handle_host_event(hostname, event)
        log_event("for host: #{hostname.inspect}", event)
        publish_data_for(hostname, event['stdout'] + "\n", 'stdout') if event['stdout']
        case event['event']
        when 'runner_on_ok'
          publish_exit_status_for(hostname, 0) if @exit_statuses[hostname].nil?
        when 'runner_on_unreachable'
          publish_exit_status_for(hostname, 1)
        when 'runner_on_failed'
          publish_exit_status_for(hostname, 2) if event['ignore_errors'].nil?
        end
      end

      def handle_broadcast_data(event)
        log_event("broadcast", event)
        if event['event'] == 'playbook_on_stats'
          header, *rows = event['stdout'].strip.lines.map(&:chomp)
          @outputs.keys.select { |key| key.is_a? String }.each do |host|
            line = rows.find { |row| row =~ /#{host}/ }
            publish_data_for(host, [header, line].join("\n"), 'stdout')
          end
        else
          broadcast_data(event['stdout'] + "\n", 'stdout')
        end
      end

      def write_inventory
        inventory_script = <<~INVENTORY_SCRIPT
          #!/bin/sh
          cat <<-EOS
          #{JSON.dump(@inventory)}
          EOS
        INVENTORY_SCRIPT
        path = File.join(@root, 'inventory', 'hosts')
        File.write(path, inventory_script)
        File.chmod(0o0755, path)
      end

      def write_playbook
        File.write(File.join(@root, 'project', 'playbook.yml'), @playbook)
      end

      def start_ansible_runner
        command = ['ansible-runner', 'run', @root, '-p', 'playbook.yml']
        initialize_command(*command)
        logger.debug("[foreman_ansible] - Running command '#{command.join(' ')}'")
      end

      def prepare_directory_structure
        inner = %w[inventory project].map { |part| File.join(@root, part) }
        ([@root] + inner).each do |path|
          FileUtils.mkdir_p path
        end
      end

      def log_event(description, event)
        # TODO: replace this ugly code with block variant once https://github.com/Dynflow/dynflow/pull/323
        # arrives in production
        logger.debug("[foreman_ansible] - handling event #{description}: #{JSON.pretty_generate(event)}") if logger.level <= ::Logger::DEBUG
      end

      # Each per-host task has inventory only for itself, we must
      # collect all the partial inventories into one large inventory
      # containing all the hosts.
      def rebuild_inventory(input)
        action_inputs = input.values.map { |hash| hash[:input][:action_input] }
        hostnames = action_inputs.map { |hash| hash[:name] }
        inventories = action_inputs.map { |hash| hash[:ansible_inventory] }
        host_vars = inventories.map { |i| i['_meta']['hostvars'] }.reduce(&:merge)

        { '_meta' => { 'hostvars' => host_vars },
          'all' => { 'hosts' => hostnames,
                     'vars' => inventories.first['all']['vars'] } }
      end

      def working_dir
        return @root if @root
        dir = ForemanAnsibleCore.settings[:working_dir]
        @tmp_working_dir = true
        if dir.nil?
          Dir.mktmpdir
        else
          Dir.mktmpdir(nil, File.expand_path(dir))
        end
      end

      def rebuild_secrets(inventory, input)
        input.each do |host, host_input|
          secrets = host_input['input']['action_input']['secrets']
          per_host = secrets['per-host'][host]

          new_secrets = {
            'ansible_ssh_pass' => inventory['ssh_password'] || per_host['ansible_ssh_pass'],
            'ansible_sudo_pass' => inventory['sudo_password'] || per_host['ansible_sudo_pass']
          }
          inventory['_meta']['hostvars'][host].update(new_secrets)
        end

        inventory
      end
    end
  end
end
