class SellerNotifier
  # Sends a raw WhatsApp text message to an arbitrary phone number (the seller),
  # independent of any customer conversation, using the same Evolution API
  # instance already configured on the "PRFIXO" inbox's Channel::Whatsapp.
  def self.call(seller_phone:, message:)
    channel = Channel::Whatsapp.find_by(provider: 'evolution', phone_number: '+552232348685')
    return Rails.logger.error('[SellerNotifier] PRFIXO Evolution channel not found') unless channel

    api_url = channel.provider_config['api_url']
    admin_token = channel.provider_config['admin_token']
    instance_name = channel.provider_config['instance_name']

    HTTParty.post(
      "#{api_url.chomp('/')}/message/sendText/#{instance_name}",
      headers: { 'apikey' => admin_token, 'Content-Type' => 'application/json' },
      body: { number: seller_phone.delete('+'), text: message }.to_json,
      timeout: 15
    )
  end
end
