# frozen_string_literal: true

class Api::V1::OwnerFinance::StatementsController < Api::V1::OwnerFinance::BaseController
  def import
    uploaded = params[:file]
    return render_invalid('Выберите файл выписки (.pdf, .txt или .csv)') unless valid_upload?(uploaded)
    return render_invalid('Файл превышает 25 МБ') if oversized_upload?(uploaded)

    result = OwnerFinance::StatementImportService.new(
      filename: uploaded.original_filename,
      content: uploaded.read,
      account_record_id: params[:account_record_id]
    ).perform
    render json: result
  rescue ArgumentError, RuntimeError, Errno::ENOENT => e
    render_invalid(e.message)
  end

  private

  def valid_upload?(uploaded)
    uploaded.respond_to?(:read) && uploaded.respond_to?(:original_filename)
  end

  def oversized_upload?(uploaded)
    uploaded.respond_to?(:size) && uploaded.size.to_i > OwnerFinance::StatementImportService::MAX_UPLOAD_BYTES
  end

  def render_invalid(message)
    render json: { error: message }, status: :unprocessable_content
  end
end
