class Internal::Voice::JanusWebsocketAuthorizationsController < ApplicationController
  def show
    authorized = Telephony::JanusWebsocketTicket.authorize?(
      ticket: request.headers['X-Janus-Ticket'],
      origin: request.headers['X-Janus-Origin'],
      path: request.headers['X-Janus-Path']
    )

    return head :no_content if authorized

    head :unauthorized
  end
end
