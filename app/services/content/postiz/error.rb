module Content::Postiz
  class Error < StandardError
    attr_reader :code, :status, :details

    def initialize(code:, message:, status: :bad_gateway, details: nil)
      super(message)
      @code = code
      @status = status
      @details = details
    end
  end
end
