# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channel::WebWidget do
  context 'when
  web widget channel' do
    let!(:channel_widget) { create(:channel_widget) }

    it 'generates the canonical SDK entry point with an older cached SDK fallback' do
      expect(channel_widget.web_widget_script).to include('(window.onelinkSDK || window.chatwootSDK).run(')
      expect(channel_widget.web_widget_script).to include("websiteToken: '#{channel_widget.website_token}'")
    end

    it 'pre chat options' do
      expect(channel_widget.pre_chat_form_options['pre_chat_message']).to eq 'Share your queries or comments here.'
      expect(channel_widget.pre_chat_form_options['pre_chat_fields'].length).to eq 3
    end
  end
end
