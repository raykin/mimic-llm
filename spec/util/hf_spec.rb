require_relative "../../lib/mimic/util/hf"
require "net/http"

RSpec.describe Mimic::Util::Hf do
  def response(klass, body)
    instance_double(klass, body: body).tap { |r| allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(klass == Net::HTTPOK) }
  end

  def stub_endpoint(value)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("HF_ENDPOINT", anything) { |_key, fallback| value || fallback }
  end

  it "asks huggingface.co when HF_ENDPOINT is unset" do
    stub_endpoint(nil)
    allow(Net::HTTP).to receive(:start).and_return(response(Net::HTTPOK, "[]"))

    described_class.new.tree("unsloth/x-GGUF")

    expect(Net::HTTP).to have_received(:start).with("huggingface.co", 443, hash_including(use_ssl: true))
  end

  # HF_ENDPOINT is huggingface_hub's own override, so every other HF client on
  # a mirrored box already points at the same host this one has to.
  it "asks the host named by HF_ENDPOINT" do
    stub_endpoint("https://hf-mirror.com")
    allow(Net::HTTP).to receive(:start).and_return(response(Net::HTTPOK, "[]"))

    described_class.new.tree("unsloth/x-GGUF")

    expect(Net::HTTP).to have_received(:start).with("hf-mirror.com", 443, hash_including(use_ssl: true))
  end

  it "falls back to the origin when HF_ENDPOINT is set but empty" do
    stub_endpoint("")
    allow(Net::HTTP).to receive(:start).and_return(response(Net::HTTPOK, "[]"))

    described_class.new.tree("unsloth/x-GGUF")

    expect(Net::HTTP).to have_received(:start).with("huggingface.co", 443, hash_including(use_ssl: true))
  end

  it "tolerates a trailing slash on HF_ENDPOINT" do
    stub_endpoint("https://hf-mirror.com/")
    http = instance_double(Net::HTTP, get: response(Net::HTTPOK, "[]"))
    allow(Net::HTTP).to receive(:start) { |*, &block| block.call(http) }

    described_class.new.tree("unsloth/x-GGUF")

    expect(http).to have_received(:get).with("/api/models/unsloth/x-GGUF/tree/main?expand=true&recursive=true")
  end

  it "parses the file listing of a repo" do
    allow(Net::HTTP).to receive(:start).and_return(response(Net::HTTPOK, '[{"path":"a.gguf","size":10}]'))

    expect(described_class.new.tree("unsloth/x-GGUF")).to eq([{ "path" => "a.gguf", "size" => 10 }])
  end

  it "asks the API once per repo" do
    client = described_class.new
    allow(Net::HTTP).to receive(:start).and_return(response(Net::HTTPOK, "[]"))

    2.times { client.tree("unsloth/x-GGUF") }

    expect(Net::HTTP).to have_received(:start).once
  end

  # A repo that 404s, a DNS failure and a truncated body all mean the same
  # thing to the caller -- no upstream answer -- and none of them may take
  # down the rest of a scan.
  it "returns nil for a non-success response" do
    allow(Net::HTTP).to receive(:start).and_return(response(Net::HTTPNotFound, "not found"))

    expect(described_class.new.tree("unsloth/nope")).to be_nil
  end

  it "returns nil when the request raises" do
    allow(Net::HTTP).to receive(:start).and_raise(SocketError, "getaddrinfo")

    expect(described_class.new.tree("unsloth/x-GGUF")).to be_nil
  end

  it "returns nil when the body is not a JSON array" do
    allow(Net::HTTP).to receive(:start).and_return(response(Net::HTTPOK, "{"))

    expect(described_class.new.tree("unsloth/x-GGUF")).to be_nil
  end

  it "caches the failure so a dead repo is not retried per model" do
    client = described_class.new
    allow(Net::HTTP).to receive(:start).and_raise(SocketError, "getaddrinfo")

    2.times { client.tree("unsloth/x-GGUF") }

    expect(Net::HTTP).to have_received(:start).once
  end
end
