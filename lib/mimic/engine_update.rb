require_relative "result"
require_relative "services/engines"

module Mimic
  # Reports how far behind upstream each engine checkout is and prints the
  # rebuild commands. Nothing is built here -- a CUDA rebuild takes 10-25
  # minutes and belongs in the user's own tmux window.
  class EngineUpdate
    REBUILD_WARNING = "CUDA rebuild takes 10-25 min -- run these in a tmux window, not here. " \
                      "Restart llama-server afterwards (`llm restart`).".freeze

    def initialize(pastel:)
      @pastel = pastel
    end

    def run
      pending = Services::Engines::ENGINES.each_key.filter_map { |name| check(name) }
      return puts @pastel.green("Update pass complete.") if pending.empty?

      puts "-- rebuild required --"
      puts "#{@pastel.yellow(REBUILD_WARNING)}\n\n"
      pending.each { |name, command| print_build_block(name, command) }
      puts "If a build regresses, `llm update --rollback <engine>` prints the command to rebuild the previous commit."
    end

    # Returns nil once the command is printed, or a failing Result.
    def rollback(name)
      sha = Services::Engines.last_good(name)
      return Result.error("no recorded last-good commit for #{name}") unless sha

      puts "Rebuild #{name} at last-good #{sha[0, 9]}:\n"
      print_build_block(name, Services::Engines.build_command(Services::Engines::ENGINES.fetch(name)[:repo], ref: sha))
      nil
    end

    private

    # Returns [name, build command] when the checkout is behind, nil otherwise.
    def check(name)
      info = Services::Engines.status(name)
      return skip(name, "not checked out -- skipped") if info.nil?
      return skip(name, "working tree dirty -- skipped") if info[:dirty]

      if info[:behind].zero?
        puts "#{name}: #{@pastel.green('up to date')} (#{info[:local]})"
        return nil
      end

      Services::Engines.record_last_good(name, info[:local])
      puts "#{name}: #{@pastel.yellow("#{info[:behind]} commits behind")} #{info[:local]} -> #{info[:remote]}"
      puts "  latest: #{info[:subject]}"
      [name, Services::Engines.build_command(info[:repo])]
    end

    def skip(name, reason)
      puts "#{name}: #{@pastel.yellow(reason)}"
      nil
    end

    def print_build_block(title, command)
      puts @pastel.bold(title)
      puts "#{@pastel.cyan(command)}\n"
    end
  end
end
