# frozen_string_literal: true

class Api::V1::Accounts::Scheduling::TemplateMasterController < Api::V1::Accounts::Scheduling::BaseController
  def generate
    result = Scheduling::AiTemplateMasterService.new(
      account: Current.account,
      language: params[:language],
      languages: params[:languages],
      bilingual: params[:bilingual],
      scenario_keys: params[:scenario_keys],
      options: params[:options] || {}
    ).call

    render json: result.merge(payload: result), status: :ok
  end

  def validate
    validator = Whatsapp::TemplateUtilityValidator.new(
      body_text: params[:body_text].presence || params[:body],
      buttons: params[:buttons],
      language: params[:language],
      category: params[:category] || 'UTILITY',
      expected_variables_count: params[:expected_variables_count],
      strict_length: parse_boolean(params[:strict_length], default: true),
      strict_trailing: parse_boolean(params[:strict_trailing], default: true),
      bilingual: parse_boolean(params[:bilingual], default: false),
      languages: params[:languages]
    ).call

    data = validator.to_h
    render json: data.merge(payload: data), status: :ok
  end
end
