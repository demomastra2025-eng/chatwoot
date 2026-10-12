class Api::V1::Accounts::Scheduling::CabinetsController < Api::V1::Accounts::Scheduling::BaseController
  def index
    cabinets = Scheduling::CabinetCatalog.new(account: Current.account).cabinets

    render_payload(cabinets, meta: { count: cabinets.size })
  end
end
