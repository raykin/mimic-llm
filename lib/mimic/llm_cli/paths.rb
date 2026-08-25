require_relative "../ui"
require "pathname"
require_relative "base"
require_relative "../llm_config"

module Mimic
  module LlmCli
    # `llm path` -- the directories scanned for GGUF files.
    class Paths < Base
      desc "add DIR", "add a directory to the model search paths"
      def add(dir)
        target = Pathname.new(dir).expand_path
        cfg = LlmConfig.load
        case cfg.search_paths.add(target)
        when :builtin then puts "#{target} is already searched by default."
        when :duplicate then puts "#{target} is already a search path."
        else
          abort "not a directory: #{target}" unless target.directory?

          cfg.save
          puts "#{Ui.green('Added')} #{target}"
        end
      end

      desc "rm DIR", "remove a directory from the model search paths"
      def rm(dir)
        target = Pathname.new(dir).expand_path
        cfg = LlmConfig.load
        status = cfg.search_paths.remove(target)
        abort "#{target} is a builtin search path and cannot be removed" if status == :builtin
        abort "#{target} is not a configured search path" if status == :missing

        cfg.save
        puts "#{Ui.green('Removed')} #{target}"
      end

      desc "list", "show every directory scanned for models"
      def list
        builtin = LlmConfig::BUILTIN_MODEL_DIRS
        LlmConfig.load.search_paths.each do |directory|
          mark = directory.directory? ? Ui.green("✓") : Ui.red("✗")
          tag = builtin.include?(directory) ? Ui.gray(" (builtin)") : ""
          puts "  #{mark} #{directory}#{tag}"
        end
      end
    end
  end
end
