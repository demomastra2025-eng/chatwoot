class Webhooks::MetaLeadFormsController < ApplicationController
  include MetaTokenVerifyConcern

  before_action :verify_meta_signature!, only: :events

  def verify
    if params['hub.mode'] == 'subscribe' && valid_token?(params['hub.verify_token'])
      render plain: params['hub.challenge']
    else
      head :forbidden
    end
  end

  def events
    ::LeadForms::MetaProcessService.new(payload: params.permit!.to_h).perform
    head :ok
  rescue StandardError => e
    Rails.logger.error("Meta lead form webhook failed: #{e.class}: #{e.message}")
    head :ok
  end

  private

  def configured_verify_tokens
    tokens = LeadForm.where(source_kind: 'meta')
                     .where("settings ? 'verify_token'")
                     .pluck(Arel.sql("settings ->> 'verify_token'"))
    tokens << ENV.fetch('META_LEAD_FORMS_VERIFY_TOKEN', nil)
    tokens.compact_blank
  end

  def lead_forms_from_payload
    Array(params.to_unsafe_h['entry']).flat_map do |entry|
      Array(entry['changes']).filter_map do |change|
        value = change.fetch('value', {})
        form_id = value['form_id'].presence || value['leadgen_form_id'].presence
        page_id = value['page_id'].presence || entry['id'].presence
        scope = LeadForm.active.where(source_kind: 'meta')
        (scope.find_by(external_ref: form_id) if form_id.present?) ||
          (scope.where("settings ->> 'meta_form_id' = ?", form_id).first if form_id.present?) ||
          (scope.where("settings ->> 'meta_page_id' = ?", page_id).first if page_id.present?)
      end
    end.uniq
  end

  def meta_app_secrets
    [
      *lead_forms_from_payload.flat_map { |lead_form| channel_meta_app_secrets(meta_connection_channel(lead_form)) },
      GlobalConfigService.load('FB_APP_SECRET', nil),
      GlobalConfigService.load('INSTAGRAM_APP_SECRET', nil),
      GlobalConfigService.load('WHATSAPP_APP_SECRET', nil)
    ].compact_blank.uniq
  end

  def meta_connection_channel(lead_form)
    inbox_id = lead_form.settings.to_h['meta_connection_inbox_id'].presence
    lead_form.account.inboxes.find_by(id: inbox_id)&.channel
  end

  def valid_token?(token)
    token.present? && configured_verify_tokens.include?(token)
  end
end
