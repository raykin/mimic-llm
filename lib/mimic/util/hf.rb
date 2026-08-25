require "net/http"
require "json"
require "uri"

module Mimic
  module Util
    # One instance per scan: a repo is fetched once and the answer -- including
    # a failure -- is kept, so several quants out of the same repo cost one
    # request. `expand=true` is what turns the listing into per-file
    # `size`/`lastCommit`; without it the endpoint returns paths only.
    #
    # HF_ENDPOINT is huggingface_hub's own origin override, so a box already
    # pointed at a mirror for downloads gets its API calls sent the same way.
    class Hf
      ORIGIN = "https://huggingface.co".freeze
      TIMEOUT = 10

      def initialize
        @trees = {}
      end

      def tree(repo_id)
        return @trees[repo_id] if @trees.key?(repo_id)

        @trees[repo_id] = fetch(repo_id)
      end

      private

      # Every failure mode here -- 404, DNS, TLS, timeout, truncated JSON --
      # means the same thing to the caller and none of them may take down the
      # rest of a scan, so the rescue is deliberately wide.
      def fetch(repo_id)
        response = get(URI("#{endpoint}/api/models/#{repo_id}/tree/main?expand=true&recursive=true"))
        return nil unless response.is_a?(Net::HTTPSuccess)

        parsed = JSON.parse(response.body)
        parsed.is_a?(Array) ? parsed : nil
      rescue StandardError
        nil
      end

      def endpoint
        configured = ENV.fetch("HF_ENDPOINT", "").sub(%r{/+\z}, "")
        configured.empty? ? ORIGIN : configured
      end

      def get(uri)
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
          http.get(uri.request_uri)
        end
      end
    end
  end
end
