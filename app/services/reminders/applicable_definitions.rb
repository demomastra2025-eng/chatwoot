class Reminders::ApplicableDefinitions
  ENTITY_KIND_BY_CLASS = {
    'Conversation' => 'conversation',
    'Crm::Deal' => 'deal',
    'Crm::Task' => 'task',
    'Scheduling::Appointment' => 'appointment'
  }.freeze

  class << self
    def call(definitions:, remindable:)
      entity_kind = entity_kind_for(remindable)

      Array(definitions).filter_map do |definition|
        normalized = Reminders::DefinitionNormalizer.call(definition)
        next unless normalized.is_a?(Hash)
        next unless applicable?(normalized, entity_kind)

        normalized
      end
    end

    def entity_kind_for(remindable)
      ENTITY_KIND_BY_CLASS.fetch(remindable.class.name) do
        raise ArgumentError, "Unsupported remindable: #{remindable.class.name}"
      end
    end

    private

    def applicable?(definition, entity_kind)
      declared_kind = definition['entity_kind'].to_s
      declared_kind.blank? || declared_kind == entity_kind
    end
  end
end
