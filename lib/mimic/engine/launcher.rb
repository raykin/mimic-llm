require "pathname"

module Mimic
  module Engine
    class Launcher
      def initialize(log_file:, pid_file:, chdir:)
        @log_file = log_file
        @pid_file = pid_file
        @chdir = chdir
      end

      def spawn(command)
        @pid_file.dirname.mkpath
        log = File.open(@log_file, "ab")
        begin
          pid = Process.spawn(*command, out: log, err: log, chdir: @chdir.to_s, pgroup: true)
        ensure
          log.close
        end
        @pid_file.write(pid.to_s)
        pid
      end
    end
  end
end
