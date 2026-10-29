module Contacts::LanguageLexicon
  KAZAKH_SPECIAL_LETTERS = /[әғқңөұүһі]/
  UKRAINIAN_LETTERS = /[їєґ]/
  BELARUSIAN_LETTERS = /[ў]/
  RUSSIAN_ONLY_LETTERS = /[щъ]/

  SHARED_ACRONYMS = %w[
    УЗИ МРТ КТ ИИН ОСМС ЭКГ ФГДС ОАК ОАМ ПЦР КТГ ДМС СМС ТОО ИП ВНЖ
    SMS ID VIP KASPI КАСПИ QR PDF
  ].to_set.freeze

  NEUTRAL_FILLERS = %w[
    алло ало мм мхм ага угу ок окей ok okay да-да
  ].to_set.freeze

  SHARED_MEDICAL_LOANWORDS = %w[
    гинеколог терапевт педиатр невропатолог невролог стоматолог ортодонт хирург
    лор кардиолог эндокринолог дерматолог уролог офтальмолог окулист маммолог
    онколог гастроэнтеролог ревматолог травматолог ортопед психиатр психолог
    аллерголог иммунолог пульмонолог нефролог проктолог флеболог узист
    анализ анализы скрининг консультация клиника адрес телефон номер кабинет
    талон чек оплата каспи рентген томография флюорография вакцина прививка
    система укол массаж физио стационар лаборатория регистратура доктор
  ].to_set.freeze

  KAZAKH_KNOWN_STEMS = %w[
    сәлем қайырлы кешір өтін айтың қалай жақсы жоқ иә бірақ ертең бүгін
    қашан қанша қай қандай дәрігер баға рақмет біз сіз мен осы мына
    жазыл қабылда уақыт сағат бала тіс ауыр бола керек
  ].freeze

  KAZAKH_PLAIN_WORDS = %w[
    рахмет рахмат салем саламатсыз салеметсиз саламатсызба салеметсизбе
    кайырлы кандай канша каншадан болады болмайды болама болад болсын
    керек емес жок жаксы жарайды келген келди келем келемин барамын
    кешке ертен бугин уакыт кашан кайда калай неше нешеде деп дегем еди
    жане бирак себеби кейин кеше бурын дейин осы мына мен мени маган
    сиз сизге сиздерде биз бизге жазылу жазылуга жазылам жазылайын жазып
    келе алмаймын алмайды алмаймыз ма ме ба бе па пе даригер даригерге
    бала балага ауырып ауырады тис кулак кабылдау кабылдайды багасы турады
    тегин акылы мекенжай кай сагат сагатта танертен тусте апта куни
    айтынызшы жиберинизши барма бармыз бос
  ].to_set.freeze

  KAZAKH_PLAIN_SUFFIXES = /(?:нызшы|низши|мызба|мизбе|сыздар|сиздер|маймын|меймин|лайын|лейин|луга|луге)\z/

  KAZAKH_LATIN_STEMS = %w[
    salem salamat rahmet raxmet raqmet kerek bolad bolma zhok joq zhaksy jaksy jaqsy
    erten bugin kashan qashan qansha kansha dariger jazyl zhazyl uakyt uaqyt sagat keled
  ].freeze

  RUSSIAN_MARKED_WORDS = %w[
    здравствуйте здравствуй привет добрый день вечер утро утром вечером днем днём
    можно нужно надо хочу хотела хотел записаться запишите запись отмена
    сколько стоит цена стоимость сегодня завтра послезавтра сейчас когда куда где
    какой какая какие какого какую спасибо пожалуйста подскажите скажите
    принимает работает свободно окошко время часов утра вечера меня мне мной
    мой моя мои моего моей ребенка ребенок детей врачу врача почему потому
    если или чтобы будет было были есть нет да хорошо ладно конечно согласна
    согласен верно правильно жду поняла понял отменить перенести узнать уточнить
    прием приём вас вам вами нам нас наш наша только очень еще ещё уже тоже
    просто через после перед около
  ].to_set.freeze

  RUSSIAN_MARKED_SUFFIXES = /(?:ться|тся|ость|ение|ание|ого|его|ому|ему|ыми|ими|уйте|айте|яйте)\z/

  SCRIPT_MATCHERS = [
    [/\p{Han}/, 'zh_CN'],
    [/\p{Hangul}/, 'ko'],
    [/\p{Hiragana}|\p{Katakana}/, 'ja'],
    [/\p{Arabic}/, 'ar'],
    [/\p{Hebrew}/, 'he'],
    [/\p{Armenian}/, 'hy'],
    [/\p{Georgian}/, 'ka'],
    [/\p{Devanagari}/, 'hi'],
    [/\p{Thai}/, 'th'],
    [/\p{Greek}/, 'el'],
    [UKRAINIAN_LETTERS, 'uk'],
    [BELARUSIAN_LETTERS, 'be']
  ].freeze

  module_function

  def kazakh_plain_word?(lower)
    KAZAKH_PLAIN_WORDS.include?(lower) || lower.match?(KAZAKH_PLAIN_SUFFIXES)
  end

  def russian_marked_word?(lower)
    lower.match?(RUSSIAN_ONLY_LETTERS) || RUSSIAN_MARKED_WORDS.include?(lower) || lower.match?(RUSSIAN_MARKED_SUFFIXES)
  end

  def kazakh_known_stem?(lower)
    KAZAKH_KNOWN_STEMS.any? { |stem| lower.start_with?(stem) }
  end

  def kazakh_latin_word?(lower)
    folded = lower.tr('äöüğşñıńáóúý', 'aougsninaouy')
    KAZAKH_LATIN_STEMS.any? { |stem| folded.start_with?(stem) }
  end

  def detect_non_cyrillic_script(lower)
    match = SCRIPT_MATCHERS.find { |regex, _code| lower.match?(regex) }
    return :"lang_#{match[1]}" if match

    detect_latin_script(lower)
  end

  def detect_latin_script(lower)
    return(kazakh_latin_word?(lower) ? :kk_strong : :lang_en) if lower.match?(/\A[a-z'-]+\z/)
    return :kk_strong if lower.match?(/\A[\p{Latin}'-]+\z/) && kazakh_latin_word?(lower)

    nil
  end
end
