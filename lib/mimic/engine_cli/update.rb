require_relative "../ui"
require_relative "../result"
require_relative "registry"
require_relative "source"

module Mimic
  module EngineCli
    class Update
      REBUILD_NOTE = "CUDA rebuild takes 10-25 min per engine. " \
                     "Restart llama-server afterwards (`llm restart`).".freeze
      DIVIDER = ("-" * 64).freeze

      def run
        pending = Registry.names.filter_map { |name| check(name) }
        return puts Ui.green("Update pass complete.") if pending.empty?

        puts DIVIDER
        puts Ui.bold("rebuilding: #{pending.map(&:first).join(', ')}")
        puts Ui.yellow(REBUILD_NOTE)
        failed = pending.reject { |name, command| run_build(name, command) }
        puts DIVIDER
        return puts Ui.green("Rebuild complete.") if failed.empty?

        puts Ui.red("failed: #{failed.map(&:first).join(', ')}")
        puts "`llm engines update --rollback <engine>` rebuilds the last-good commit."
      end

      def rollback(name)
        sha = Source.last_good(name)
        return Result.error("no recorded last-good commit for #{name}") unless sha

        puts "Rebuilding #{name} at last-good #{sha[0, 9]}:\n"
        return nil if run_build(name, Source.build_command(name, ref: sha))

        Result.error("#{name} rollback build failed -- see output above")
      end

      private

      # Returns [name, build command] when the checkout is behind, nil otherwise.
      def check(name)
        info = Source.status(name)
        return skip(name, "not checked out -- skipped") if info.nil?
        return skip(name, "working tree dirty -- skipped") if info[:dirty]

        if info[:behind].zero?
          puts "#{name}: #{Ui.green('up to date')} (#{info[:local]})"
          return nil
        end

        Source.record_last_good(name, info[:local])
        puts "#{name}: #{Ui.yellow("#{info[:behind]} commits behind")} " \
             "#{info[:local]} -> #{info[:remote]} (#{info[:subject]})"
        [name, Source.build_command(name)]
      end

      def skip(name, reason)
        puts "#{name}: #{Ui.yellow(reason)}"
        nil
      end

      def run_build(name, command)
        puts "\n#{Ui.bold("[#{name}]")}"
        system(command)
      end
    end
  end
end
