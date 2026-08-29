require "pathname"
require_relative "llm_config"
require_relative "paths"
require_relative "model/footprint"
require_relative "model/header"
require_relative "model/memory"

module Mimic
  # A GGUF on disk together with the multimodal projector that belongs to it.
  #
  # llama.cpp ships a vision model as two files: the decoder, and a projector
  # (the vision tower plus the adapter into the decoder's hidden dim) loaded
  # with --mmproj. The projector cannot run on its own, so a scan pairs it
  # onto its model rather than listing it as one.
  class Model
    class << self
      # llama.cpp's own convert/clip.cpp mark a projector GGUF with
      # general.type == "mmproj" -- naming (mmproj-prefixed, mmproj-suffixed,
      # or neither) is convention, not a contract, so the header is the only
      # reliable signal.
      def projector?(path) = Header.new(path).metadata["general.type"] == "mmproj"

      def pair(entries)
        entries.reject { |path, _scan_dir| projector?(path) }
               .map { |path, scan_dir| new(path, scan_dir) }
      end

      # The directory is the binding; stem only breaks a tie when a
      # directory holds several projectors. The glob has to run against the
      # realpath directory: ~/hf-models is a tree of per-file symlinks, and
      # a model's projector usually exists only in the target directory.
      def projector_for(model_path)
        real = Pathname.new(model_path.to_s).realpath
        candidates = Pathname.glob(real.dirname / "*.gguf").select { |c| c.file? && projector?(c) }.sort
        return nil if candidates.empty?

        stem = LlmConfig::Settings.alias_for(model_path.to_s).downcase
        candidates.find { |c| c.basename.to_s.downcase.include?(stem) } ||
          (candidates.one? ? candidates.first : nil)
      rescue SystemCallError
        nil
      end
    end

    def initialize(path, scan_dir = nil)
      @path = Pathname.new(path.to_s)
      @scan_dir = scan_dir
    end

    attr_reader :path, :scan_dir

    def real = @real ||= path.realpath
    def model_alias = @model_alias ||= LlmConfig::Settings.alias_for(path.to_s)
    def vision? = !projector.nil?
    def embedding? = @embedding ||= header.embedding? == true

    def projector
      return @projector if defined?(@projector)

      @projector = self.class.projector_for(path)
    end

    def memory = @memory ||= Memory.new(path, header)

    def supports_mtp? = header.supports_mtp?
    def moe? = header.moe? == true

    def footprint(ctx, cache_type, compute_mib: nil, drafting: false, slots: 1, reclaimable_mib: 0,
                  mmproj_path: projector)
      Footprint.new(header, ctx: ctx, cache_type: cache_type, weights_bytes: weights_bytes(mmproj_path),
                            compute_mib: compute_mib, drafting: drafting, slots: slots,
                            reclaimable_mib: reclaimable_mib)
    end

    private

    def header = @header ||= Header.new(path)

    def weights_bytes(mmproj_path)
      File.size(path) + projector_bytes(mmproj_path)
    rescue SystemCallError
      nil
    end

    # A vision model's projector is loaded onto the GPU with --mmproj, so it
    # spends VRAM the decoder's own file size does not account for.
    def projector_bytes(mmproj_path)
      mmproj_path ? File.size(mmproj_path) : 0
    rescue SystemCallError
      0
    end
  end
end
