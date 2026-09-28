class Api::V1::Accounts::Scheduling::RetiredFinanceMutationsController < Api::V1::Accounts::Scheduling::BaseController
  def reject
    Scheduling::Appointments::RetiredFinanceGuard.reject_mutation!
  end
end
