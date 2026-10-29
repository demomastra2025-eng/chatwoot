class Api::V1::Accounts::Scheduling::MedelementPatientsController < Api::V1::Accounts::Scheduling::BaseController
  before_action :ensure_patient_context_employee!
  before_action :set_directory

  def search
    query = request_body_value!(:query)
    if !Contacts::IinPrivacy.can_view_iin? && Contacts::IinPrivacy.iin_search_query?(query)
      return render_payload({ patients: [], reason: 'unsupported', truncated: false })
    end

    results = @directory.search(query)
    render_payload(mask_directory_results(results))
  end

  def create
    contact = @directory.import(request_body_value!(:token))
    render_payload(Scheduling::PayloadBuilder.contact(contact))
  end

  private

  DIRECTORY_EXPLICIT_IIN_KEYS = %w[iin medelement_iin iin_masked].freeze

  def mask_directory_results(results)
    return results if Contacts::IinPrivacy.can_view_iin?
    return results.map { |item| mask_directory_item(item) } if results.is_a?(Array)
    return results unless results.is_a?(Hash)

    masked = results.dup
    masked[:patients] = masked[:patients].map { |item| mask_directory_item(item) } if masked[:patients].is_a?(Array)
    masked['patients'] = masked['patients'].map { |item| mask_directory_item(item) } if masked['patients'].is_a?(Array)
    masked
  end

  def mask_directory_item(item)
    return item unless item.is_a?(Hash)

    masked = DIRECTORY_EXPLICIT_IIN_KEYS.each_with_object(item.dup) do |key, out|
      Contacts::IinPrivacy.mask_hash_entry!(out, key)
      Contacts::IinPrivacy.mask_hash_entry!(out, key.to_sym)
    end
    masked['identifier'] = Contacts::IinPrivacy.mask_identifier(masked['identifier']) if masked.key?('identifier')
    masked[:identifier] = Contacts::IinPrivacy.mask_identifier(masked[:identifier]) if masked.key?(:identifier)
    masked
  end

  def set_directory
    adapter = Scheduling::ProviderCommands::Registry.resolve!(account: Current.account, provider: 'medelement', require_hook: true)
    @directory = Integrations::Medelement::PatientDirectorySearch.new(account: Current.account, hook: adapter.hook, user: Current.user)
  end

  def request_body_value!(key)
    raise ActionController::ParameterMissing, key unless request.media_type == 'application/json'

    body = JSON.parse(request.raw_post)
    raise ActionController::ParameterMissing, key unless body.is_a?(Hash)

    body.fetch(key.to_s) { raise ActionController::ParameterMissing, key }
  rescue JSON::ParserError
    raise ActionController::ParameterMissing, key
  end
end
