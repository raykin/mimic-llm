require "thor"
require "pathname"
require "pastel"
require_relative "llm_config"

module Mimic
  class LlmPathsCli < Thor
    def self.exit_on_failure? = true

    def initialize(*args)
      super
      @pastel = Pastel.new
    end

    desc "add DIR", "add a directory to the model search paths"
    def add(dir)
      target = Pathname.new(dir).expand_path
      cfg = LlmConfig.load
      case cfg.add_search_path(target)
      when :builtin then puts "#{target} is already searched by default."
      when :duplicate then puts "#{target} is already a search path."
      else
        abort "not a directory: #{target}" unless target.directory?

        cfg.save
        puts "#{@pastel.green('Added')} #{target}"
      end
    end

    desc "rm DIR", "remove a directory from the model search paths"
    def rm(dir)
      target = Pathname.new(dir).expand_path
      cfg = LlmConfig.load
      status = cfg.remove_search_path(target)
      abort "#{target} is a builtin search path and cannot be removed" if status == :builtin
      abort "#{target} is not a configured search path" if status == :missing

      cfg.save
      puts "#{@pastel.green('Removed')} #{target}"
    end

    desc "list", "show every directory scanned for models"
    def list
      builtin = LlmConfig::BUILTIN_MODEL_DIRS
      LlmConfig.load.search_paths.each do |directory|
        mark = directory.directory? ? @pastel.green("✓") : @pastel.red("✗")
        tag = builtin.include?(directory) ? @pastel.dim(" (builtin)") : ""
        puts "  #{mark} #{directory}#{tag}"
      end
    end
  end
end
