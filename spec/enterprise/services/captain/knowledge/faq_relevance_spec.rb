require 'rails_helper'

RSpec.describe Captain::Knowledge::FaqRelevance do
  def candidate(question, score, id = 1)
    Struct.new(:id, :question, :neighbor_distance).new(id, question, score.nil? ? nil : 1.0 - score)
  end

  def selection(query, *candidates)
    described_class.select(candidates, query: query)
  end

  it 'keeps the similarity floor and ambiguity margin inclusive despite float precision' do
    leader = candidate('Запись к терапевту', 0.52)
    rival = candidate('Прием терапевта', 0.44, 2)
    expect(selection('хочу к терапевту', leader, rival)[:response]).to eq(leader)
    expect(selection('хочу к терапевту', candidate('Запись к терапевту', 0.4))[:check]).to include(passed: true)
  end

  it 'keeps grammatical variants despite exact forms in another retrieved question' do
    {
      'прием терапевта' => ['Запись на прием к терапевту', 'Как проходит прием терапевта'],
      'account payments' => ['Account payment options', 'How to check payments'],
      'дәрігерге' => ['Дәрігер қабылдауы', 'Дәрігерге жазылу']
    }.each do |query, (question, other_question)|
      leader = candidate(question, 0.52)
      rival = candidate(other_question, 0.3, 2)

      expect(selection(query, leader, rival)[:response]).to eq(leader)
    end
  end

  it 'counts inflected rivals in the ambiguity margin in both directions' do
    {
      'хочу к терапевту' => ['Как записаться на прием к терапевту', 'Как проходит прием терапевта'],
      'account payments' => ['Account payment options', 'Account payments guide'],
      'дәрігерге' => ['Дәрігер қабылдауы', 'Дәрігерге жазылу']
    }.each do |query, (question, other_question)|
      leader = candidate(question, 0.52)
      rival = candidate(other_question, 0.5, 2)

      expect(selection(query, leader, rival)[:check]).to include(passed: false, reason: 'ambiguous_question_matches')
      expect(selection(query, candidate(other_question, 0.52), candidate(question, 0.5, 2))[:response]).to be_nil
    end
  end

  it 'keeps exact competing words authoritative for real typo guesses' do
    leader = candidate('Warranty refund policy', 0.52)
    rival = candidate('Warrants legal process', 0.3, 2)

    expect(selection('warrants refund', leader, rival)[:response]).to be_nil
  end

  it 'does not mistake a different topic ending in ing for a plural noun' do
    leader = candidate('Account policy', 0.52)
    rival = candidate('Accounting policy requirements', 0.3, 2)

    expect(selection('need accounting policy', leader, rival)[:check]).to include(
      passed: false, reason: 'question_not_corroborated', query_coverage: 0.5
    )
  end

  it 'does not equate derivations, short substitutes, or an added negative term with a grammatical form' do
    expect(selection('therapy', candidate('Therapist appointment', 0.6))[:response]).to be_nil
    expect(selection('clinic payments', candidate('Clinical payment', 0.6))[:response]).to be_nil
    expect(selection('cat', candidate('Cats care', 0.6))[:response]).to be_nil
    expect(selection('не хочу к терапевту', candidate('Запись к терапевту', 0.6))[:response]).to be_nil
    expect(selection('not account payments', candidate('Account payment options', 0.6))[:response]).to be_nil
  end

  it 'does not turn short word substitutions or numbers into typos' do
    expect(selection('cat', candidate('car', 0.6))[:response]).to be_nil
    expect(selection('цена 101', candidate('цена 100', 0.6))[:response]).to be_nil
    expect(selection('podiatrist', candidate('pediatrician', 0.6))[:response]).to be_nil
  end

  it 'requires every meaningful query term, rather than a generic shared brand' do
    expect(selection('цена OneLink', candidate('Возможности OneLink', 0.6))[:response]).to be_nil
    expect(selection('отменить терапевта', candidate('Запись к терапевту', 0.6))[:response]).to be_nil
  end

  it 'bounds long query/question term lists and edit comparisons' do
    leader = candidate('Запись к терапевту', 0.6)
    expect(selection((1..20).map { |index| "term#{index}" }.join(' '), leader)[:response]).to be_nil
    expect(selection('x' * 100, candidate('x' * 101, 0.6))[:response]).to be_nil
    long_question = 'терапевту ' + (1..40).map { |index| "term#{index}" }.join(' ')
    expect(selection('хочу к терапевту', candidate(long_question, 0.6))[:response]).to be_nil
  end

  it 'cannot rescue missing or non-finite native distances' do
    expect(selection('хочу к терапевту', candidate('Запись к терапевту', nil))[:response]).to be_nil
    invalid = Struct.new(:id, :question, :neighbor_distance).new(2, 'Запись к терапевту', Float::NAN)
    expect(selection('хочу к терапевту', invalid)[:response]).to be_nil
  end
end
