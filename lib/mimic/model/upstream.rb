require "pathname"
require_relative "../model"
require_relative "header"

module Mimic
  class Model
    # What the repo this GGUF came from publishes today, against what is on
    # disk.
    #
    # The comparison is byte size, not mtime: a local mtime is a download
    # timestamp and survives nothing, while the repo's file size changes on
    # every re-quantize. The blind spot is a re-quantize that lands on an
    # identical byte count.
    class Upstream
      LMSTUDIO_ROOT = Pathname.new(Dir.home) / ".lmstudio" / "models"

      def initialize(model, client:)
        @model = model
        @client = client
      end

      def repo_id
        return @repo_id if defined?(@repo_id)

        @repo_id = from_lmstudio_path || from_header
      end

      def verdict
        return :unknown if repo_id.nil? || tree.nil?
        return :gone if entry.nil?

        entry["size"] == local_size ? :current : :stale
      end

      def updated_at = entry&.dig("lastCommit", "date").to_s[0, 10].then { |date| date.empty? ? nil : date }

      private

      def real
        @real ||= @model.real
      rescue SystemCallError
        @real = @model.path
      end

      def local_size = File.size(real)

      # LM Studio lays its cache out as <root>/<owner>/<repo>/<file>, which is
      # the repo id spelled out -- no header and no network needed.
      def from_lmstudio_path
        prefix = "#{LMSTUDIO_ROOT}/"
        return nil unless real.to_s.start_with?(prefix)

        parts = real.to_s.delete_prefix(prefix).split("/")
        parts.length >= 3 ? parts[0, 2].join("/") : nil
      end

      # general.repo_url carries the quantizer's org and stops there
      # (`https://huggingface.co/unsloth`), so the repo half comes from the
      # directory the file was downloaded into. Wrong guesses fail closed:
      # the repo 404s and the verdict is :unknown.
      def from_header
        owner = Header.new(real).metadata["general.repo_url"].to_s[%r{huggingface\.co/([^/\s]+)}, 1]
        owner && "#{owner}/#{real.dirname.basename}"
      end

      def tree
        return @tree if defined?(@tree)

        @tree = repo_id && @client.tree(repo_id)
      end

      def entry
        return @entry if defined?(@entry)

        @entry = tree&.find do |candidate|
          candidate["type"] != "directory" && File.basename(candidate["path"].to_s) == real.basename.to_s
        end
      end
    end
  end
end
