class Integrations::Medelement::ContactCustomAttributesSetupService
  FIELDS = {
    'medelement_patient_code' => ['Medelement patient code', 'text'],
    'iin' => %w[IIN text],
    'birth_date' => ['Birth date', 'date'],
    'gender' => %w[Gender text],
    'address' => %w[Address text],
    'secondary_phones' => ['Secondary phones', 'text'],
    'phone_conflict_comment' => ['Phone conflict comment', 'text'],
    'medelement_last_synced_at' => ['Medelement last synced at', 'text']
  }.freeze

  def initialize(account:)
    @account = account
  end

  def perform
    FIELDS.each do |key, (display_name, display_type)|
      account.custom_attribute_definitions.find_or_create_by!(
        attribute_key: key,
        attribute_model: 'contact_attribute'
      ) do |definition|
        definition.attribute_display_name = display_name
        definition.attribute_display_type = display_type
      end
    end
  end

  private

  attr_reader :account
end
