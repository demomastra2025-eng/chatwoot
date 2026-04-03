class Api::V1::Accounts::ContextFieldsController < Api::V1::Accounts::BaseController
  def index
    @context_fields =
      if defined?(Captain::ContextFields)
        Captain::ContextFields.definitions_for_user(
          account: Current.account,
          user: Current.user
        )
      else
        []
      end
  end
end
