# frozen_string_literal: true

# The words of the image readers and of the agents about a customer's image. They name no kind of business: the platform serves
# companies of every kind, so what the business is comes only as data from the account (the industry of its workspace profile, when
# the workspace has one), never as text of the platform (owner 27.10).
module Captain::ImageReading::Prompt
  READ = <<~TEXT.squish.freeze
    Это изображение клиент прислал в чат компании. Перепиши весь значимый видимый текст точно так, как он написан,
    на языке оригинала: имена, даты, время, суммы, номера, названия, значения и единицы, телефоны. Сохраняй порядок и нумерацию.
    Слово или число, которое нельзя прочитать уверенно, замени на [неразборчиво] — не угадывай и ничего не додумывай.
    Если текста нет, коротко опиши, что изображено. В конце одной строкой: что это за изображение.
  TEXT
  INDUSTRY_PREFIX = 'Сфера компании: '
  INDUSTRY_MAX_LENGTH = 80
  # What the agent reads in front of the description. The description is made by a program from the pixels: it can be wrong, so
  # the agent is told so, and an agent that must rely on a detail asks the customer instead of trusting it.
  AGENT_LABEL = 'Image attachment (automatic description, it may be inaccurate)'

  module_function

  # The instruction of a reader. The line with the industry of the company is added only when the workspace profile has one.
  def read(account)
    industry = industry_of(account)
    industry ? "#{INDUSTRY_PREFIX}#{industry}. #{READ}" : READ
  end

  # The text of an image in the history the agent reads.
  def agent_text(description)
    "#{AGENT_LABEL}: #{description}"
  end

  def industry_of(account)
    value = account&.custom_attributes.to_h['industry']
    return unless value.is_a?(String)

    value.gsub(/[[:cntrl:]]/, ' ').squish.truncate(INDUSTRY_MAX_LENGTH, omission: '').presence
  end
end
