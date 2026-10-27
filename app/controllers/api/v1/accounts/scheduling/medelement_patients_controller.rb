class Api::V1::Accounts::Scheduling::MedelementPatientsController < Api::V1::Accounts::Scheduling::BaseController
  before_action :ensure_patient_context_employee!
  before_action :set_directory

  def search
    render_payload(@directory.search(params.require(:query)))
  end

  def create
    contact = @directory.import(params.require(:token))
    render_payload(Scheduling::PayloadBuilder.contact(contact))
  end

  private

  def set_directory
    adapter = Scheduling::ProviderCommands::Registry.resolve!(account: Current.account, provider: 'medelement', require_hook: true)
    @directory = Integrations::Medelement::PatientDirectorySearch.new(account: Current.account, hook: adapter.hook, user: Current.user)
  end
end
