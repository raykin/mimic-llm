require_relative "../lib/mimic"
require_relative "support/model_keyed_store"
require_relative "support/gguf_writer"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::Model do
  def in_tmp
    Dir.mktmpdir { |dir| yield Pathname.new(dir) }
  end

  # A real header, not a filename, is what marks a projector -- llama.cpp's
  # own convert scripts write general.type == "mmproj" regardless of what
  # the file is named.
  def write_projector(path)
    GgufWriter.write(path, { "general.type" => "mmproj", "clip.has_vision_encoder" => 1 })
  end

  describe "#supports_mtp?" do
    it "answers from the model's own header" do
      in_tmp do |root|
        path = root / "mtp.gguf"
        path.write("GGUF\x00nextn_predict_layers\x00", mode: "wb")

        expect(described_class.new(path).supports_mtp?).to be true
        expect(described_class.new(root / "missing.gguf").supports_mtp?).to be false
      end
    end
  end

  describe ".projector?" do
    it "recognises a projector by its header, whatever it's named" do
      in_tmp do |root|
        write_projector(root / "vision-part2.gguf")

        expect(described_class.projector?(root / "vision-part2.gguf")).to be true
      end
    end

    it "does not mistake a plain model, even one named mmproj-something, for a projector" do
      in_tmp do |root|
        FileUtils.touch(root / "mmproj-shaped-name.gguf")

        expect(described_class.projector?(root / "mmproj-shaped-name.gguf")).to be false
      end
    end
  end

  describe ".projector_for" do
    it "pairs a projector that carries no model stem at all" do
      in_tmp do |root|
        model = root / "gemma-4-31B-it-Q4_K_S.gguf"
        projector = root / "mmproj-F32.gguf"
        FileUtils.touch(model)
        write_projector(projector)

        expect(described_class.projector_for(model)).to eq(projector)
      end
    end

    it "prefers the stem-matching projector when a directory holds several" do
      in_tmp do |root|
        model = root / "Bonsai-27B-Q4_K_M.gguf"
        FileUtils.touch(model)
        [root / "mmproj-F32.gguf", root / "mmproj-Bonsai-27B-BF16.gguf"].each { |p| write_projector(p) }

        expect(described_class.projector_for(model)).to eq(root / "mmproj-Bonsai-27B-BF16.gguf")
      end
    end

    it "pairs a projector whose mmproj marker is suffixed onto the model's own name" do
      in_tmp do |root|
        model = root / "Ternary-Bonsai-27B-Q2_0.gguf"
        projector = root / "Ternary-Bonsai-27B-mmproj-Q8_0.gguf"
        FileUtils.touch(model)
        write_projector(projector)

        expect(described_class.projector_for(model)).to eq(projector)
      end
    end

    it "declines to guess between unrelated projectors" do
      in_tmp do |root|
        model = root / "model-Q4_K_M.gguf"
        FileUtils.touch(model)
        [root / "mmproj-alpha-f16.gguf", root / "mmproj-beta-f16.gguf"].each { |p| write_projector(p) }

        expect(described_class.projector_for(model)).to be_nil
      end
    end

    it "looks beside the symlink target, not beside the symlink" do
      in_tmp do |root|
        store = root / "store"
        links = root / "links"
        [store, links].each(&:mkpath)
        target = store / "model-Q4_K_M.gguf"
        projector = store / "mmproj-F32.gguf"
        FileUtils.touch(target)
        write_projector(projector)
        link = links / "model-Q4_K_M.gguf"
        FileUtils.ln_s(target, link)

        expect(described_class.projector_for(link)).to eq(projector)
      end
    end

    it "returns nil when the model file is gone" do
      expect(described_class.projector_for(Pathname.new("/nowhere/model.gguf"))).to be_nil
    end
  end

  def write_drafter(path, arch: "gemma4")
    GgufWriter.write(path, { "general.architecture" => "#{arch}-assistant", "general.type" => "model" })
  end

  def write_target(path, arch: "gemma4")
    GgufWriter.write(path, { "general.architecture" => arch })
  end

  describe ".drafter_for" do
    it "pairs the drafter beside the model, whatever it's named" do
      in_tmp do |root|
        model = root / "gemma-4-31B-it-Q4_K_S.gguf"
        drafter = root / "mtp-gemma-4-31B-it.gguf"
        write_target(model)
        write_drafter(drafter)

        expect(described_class.drafter_for(model)).to eq(drafter)
      end
    end

    it "ignores a drafter built for another architecture" do
      in_tmp do |root|
        model = root / "qwen-Q4_K_M.gguf"
        write_target(model, arch: "qwen3")
        write_drafter(root / "mtp-gemma.gguf")

        expect(described_class.drafter_for(model)).to be_nil
      end
    end

    it "prefers the stem-matching drafter when a directory holds several" do
      in_tmp do |root|
        model = root / "gemma-4-31B-it-Q4_K_S.gguf"
        write_target(model)
        [root / "mtp-gemma-4-26B-it.gguf", root / "mtp-gemma-4-31B-it.gguf"].each { |p| write_drafter(p) }

        expect(described_class.drafter_for(model)).to eq(root / "mtp-gemma-4-31B-it.gguf")
      end
    end

    it "returns nil when the model file is gone" do
      expect(described_class.drafter_for(Pathname.new("/nowhere/model.gguf"))).to be_nil
    end
  end

  describe ".pair" do
    it "drops drafters from the list and attaches them to their model" do
      in_tmp do |root|
        model = root / "gemma-4-31B-it-Q4_K_S.gguf"
        drafter = root / "mtp-gemma-4-31B-it.gguf"
        write_target(model)
        write_drafter(drafter)

        paired = described_class.pair([[model, root], [drafter, root]])

        expect(paired.map(&:path)).to eq([model])
        expect(paired.first.drafter).to eq(drafter)
      end
    end

    it "drops projectors from the list and attaches them to their model" do
      in_tmp do |root|
        model = root / "model-Q4_K_M.gguf"
        projector = root / "mmproj-F32.gguf"
        FileUtils.touch(model)
        write_projector(projector)

        paired = described_class.pair([[model, root], [projector, root]])

        expect(paired.map(&:path)).to eq([model])
        expect(paired.first.projector).to eq(projector)
        expect(paired.first).to be_vision
      end
    end

    it "leaves a text-only model without a projector" do
      in_tmp do |root|
        model = root / "model-Q4_K_M.gguf"
        FileUtils.touch(model)

        paired = described_class.pair([[model, root]])

        expect(paired.first.projector).to be_nil
        expect(paired.first).not_to be_vision
      end
    end
  end

  describe "#embedding?" do
    it "asks the GGUF header, resolved through the symlink" do
      in_tmp do |root|
        store = root / "store"
        links = root / "links"
        [store, links].each(&:mkpath)
        target = store / "bge-m3-Q8_0.gguf"
        GgufWriter.write(target, { "general.architecture" => "bert", "bert.attention.causal" => 0 })
        link = links / "bge-m3-Q8_0.gguf"
        FileUtils.ln_s(target, link)

        expect(described_class.new(link, links)).to be_embedding
      end
    end

    it "is false for a generative model" do
      in_tmp do |root|
        model = root / "chat-Q4_K_M.gguf"
        GgufWriter.write(model, { "general.architecture" => "qwen3", "qwen3.block_count" => 48 })

        expect(described_class.new(model, root)).not_to be_embedding
      end
    end

    it "is false for a file with no readable header" do
      in_tmp do |root|
        model = root / "empty.gguf"
        FileUtils.touch(model)

        expect(described_class.new(model, root)).not_to be_embedding
      end
    end
  end

  describe "#model_alias" do
    it "strips the quant marker the same way the config does" do
      model = described_class.new(Pathname.new("/m/Bonsai-27B-Q4_K_M.gguf"), Pathname.new("/m"))

      expect(model.model_alias).to eq("Bonsai-27B")
    end
  end
end
