# frozen_string_literal: true

class Public::ConfirmationRequestsController < PublicController
  def show
    confirmation_request = ConfirmationRequest.find_by!(token: params[:token])
    resolved = Confirmations::ResolveService.new(
      account: confirmation_request.account,
      confirmation_request: confirmation_request,
      decision: params[:decision],
      source: 'link'
    ).perform

    render plain: success_message(resolved), status: :ok
  rescue Confirmations::ExpiredRequestError
    render plain: 'Срок подтверждения истек.', status: :gone
  rescue ArgumentError => e
    render plain: e.message, status: :unprocessable_entity
  end

  private

  def success_message(confirmation_request)
    case confirmation_request.status
    when 'confirmed'
      'Подтверждено.'
    when 'declined'
      'Отменено.'
    when 'reschedule_requested'
      'Запрошен перенос.'
    else
      'Статус обновлен.'
    end
  end
end
