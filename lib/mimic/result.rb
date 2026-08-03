module Mimic
  Result = Data.define(:ok, :message) do
    def self.ok(message) = new(ok: true, message:)
    def self.error(message) = new(ok: false, message:)

    def ok? = ok
  end
end
