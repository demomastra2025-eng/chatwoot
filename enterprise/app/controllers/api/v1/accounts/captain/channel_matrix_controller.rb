# frozen_string_literal: true

class Api::V1::Accounts::Captain::ChannelMatrixController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action :check_admin_authorization?

  def show
    render json: matrix.payload
  end

  def update
    render json: matrix.update!(params.to_unsafe_h.slice('default_main_assistant_id', 'channels', 'assistants'))
  rescue Captain::ChannelMatrix::Invalid => e
    render json: { errors: e.errors }, status: :unprocessable_content
  rescue ActiveRecord::RecordInvalid
    error = { inbox_id: nil, assistant_id: nil, code: 'INVALID_STATE',
              message: I18n.t('captain.channel_matrix.invalid_state') }
    render json: { errors: [error] }, status: :unprocessable_content
  end

  private

  def matrix
    @matrix ||= Captain::ChannelMatrix.new(Current.account)
  end
end
