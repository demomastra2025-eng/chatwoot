# frozen_string_literal: true

require 'digest'

# What one agent handles, as the router reads it: built in code from the agent's own routing description (no model, so the
# live router and the evaluation harness see the same text). Links, phone numbers and e-mail addresses are dropped (noise for
# routing), the text is cut at a word boundary, and one capability fact is added from the tools: an agent that cannot book
# while another agent of the clinic can is marked so. Doctor names and prices stay as written: patients route by them.
# Semantic cleanup (a "main coordinator" sentence) belongs to the prompt migration, never to this code.
class Captain::Routing::CompetenceCard
  MAX_LENGTH = 1200
  LABEL_LENGTH = 60
  BOOKING_TOOL = 'create_appointment'
  NO_BOOKING_NOTE = 'Не записывает на приём.'
  CACHE_VERSION = 'v1'
  URL = %r{(?:https?://|www\.)[^\s,;()]*[^\s,;().]}i
  EMAIL = /\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b/
  # A phone number: an optional +, then at least 9 digits that may be split by spaces, dashes or brackets.
  PHONE = /(?<!\w)\+?\d(?:[\s\-()]*\d){8,}(?!\w)/

  class << self
    # candidate: a Captain::Routing::Candidate; peers: the other candidates of the clinic (for the capability fact).
    def text(candidate, peers: [])
      body = clean(candidate.routing_description)
      return '' if body.blank?

      note = NO_BOOKING_NOTE if !candidate.books_appointments? && Array(peers).any?(&:books_appointments?)
      [body, note].compact.join(' ')
    end

    # The same text, cached by everything it depends on: a changed description, tool or peer gives a new key.
    def cached_text(candidate, peers: [])
      Rails.cache.fetch(cache_key(candidate, peers), expires_in: 1.day) { text(candidate, peers: peers) }
    rescue StandardError
      text(candidate, peers: peers)
    end

    def label(name)
      squished = name.to_s.squish
      squished.length > LABEL_LENGTH ? "#{squished.first(LABEL_LENGTH - 1).rstrip}…" : squished
    end

    def clean(description)
      text = description.to_s.gsub(URL, ' ').gsub(EMAIL, ' ').gsub(PHONE, ' ').squish
      text = text.gsub(/\s+([,.;:)])/, '\1').gsub(/\(\s*\)/, '').squish
      cut(text)
    end

    private

    def cut(text)
      return text if text.length <= MAX_LENGTH

      head = text.first(MAX_LENGTH)
      boundary = head.rindex(/\s/)
      head = head.first(boundary) if boundary && boundary > MAX_LENGTH / 2
      "#{head.rstrip.sub(/[,;:\-–]\z/, '')}…"
    end

    def cache_key(candidate, peers)
      peer_signature = Array(peers).map { |peer| [peer.id, peer.books_appointments?] }.sort_by(&:first)
      digest = Digest::SHA256.hexdigest(JSON.generate([candidate.name, candidate.routing_description, Array(candidate.tool_ids).sort,
                                                       peer_signature]))
      "captain:routing_card:#{CACHE_VERSION}:#{candidate.id}:#{digest}"
    end
  end
end
