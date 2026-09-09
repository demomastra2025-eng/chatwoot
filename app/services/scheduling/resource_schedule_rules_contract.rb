class Scheduling::ResourceScheduleRulesContract
  class << self
    def parse!(params, field:, permitted:)
      value = required_value!(params, field)
      invalid!(field, 'must be an array') unless value.is_a?(Array)

      value.map do |item|
        invalid!(field, 'must be an array of objects') unless item.respond_to?(:to_h)

        parameters = item.is_a?(ActionController::Parameters) ? item : ActionController::Parameters.new(item)
        parameters.permit(*permitted).to_h
      end
    end

    private

    def required_value!(params, field)
      raise ActionController::ParameterMissing, field unless params.key?(field)

      params[field]
    end

    def invalid!(field, message)
      raise Scheduling::Error.new(
        code: 'INVALID_SCHEDULE_PAYLOAD',
        message: "#{field} #{message}",
        status: :unprocessable_content,
        details: { field: field }
      )
    end
  end
end
