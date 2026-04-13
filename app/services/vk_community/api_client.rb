class VkCommunity::ApiClient
  class ApiError < StandardError; end

  pattr_initialize [:channel!]

  def call(method_name, params = {})
    response = HTTParty.post(
      "#{base_url}/#{method_name}",
      body: params.merge(access_token: channel.access_token, v: channel.api_version),
      timeout: 60
    )
    parsed = response.parsed_response
    raise ApiError, parsed.dig('error', 'error_msg') if parsed.is_a?(Hash) && parsed['error'].present?

    parsed.fetch('response', parsed)
  end

  def user_profile(user_id)
    Array.wrap(call('users.get', user_ids: user_id, fields: 'bdate,city,screen_name,photo_200')).first.to_h.with_indifferent_access
  end

  def send_message(peer_id:, text:, reply_to_message_id: nil, attachments: [])
    params = {
      peer_id: peer_id,
      random_id: SecureRandom.random_number(2**31),
      message: text.to_s
    }
    params[:reply_to] = reply_to_message_id if reply_to_message_id.present?
    params[:attachment] = attachments.join(',') if attachments.present?
    call('messages.send', params)
  end

  def upload_attachment(attachment)
    attachment.file_type == 'image' ? upload_photo(attachment) : upload_document(attachment)
  end

  private

  def upload_photo(attachment)
    upload_server = call('photos.getMessagesUploadServer')
    tempfile = Down.download(attachment.download_url)
    response = HTTParty.post(upload_server.fetch('upload_url'), body: { photo: File.new(tempfile.path, 'rb') }, timeout: 120)
    photo = Array.wrap(call('photos.saveMessagesPhoto', response.parsed_response.slice('photo', 'server', 'hash'))).first
    "photo#{photo['owner_id']}_#{photo['id']}"
  end

  def upload_document(attachment)
    upload_server = call('docs.getMessagesUploadServer', type: 'doc')
    tempfile = Down.download(attachment.download_url)
    response = HTTParty.post(upload_server.fetch('upload_url'), body: { file: File.new(tempfile.path, 'rb') }, timeout: 120)
    saved = call('docs.save', file: response.parsed_response.fetch('file'))
    doc = saved['doc'] || saved
    "doc#{doc['owner_id']}_#{doc['id']}"
  end

  def base_url
    ENV.fetch('VK_API_BASE_URL', 'https://api.vk.com/method')
  end
end
