require "test_helper"

class VerificationLogTest < ActiveSupport::TestCase
  test "rejects a second verification on the same local day across UTC dates" do
    Time.use_zone("Asia/Seoul") do
      participant = nil
      first = nil
      travel_to(Time.zone.local(2026, 11, 15, 0, 30)) do
        participant = build_participant
        first = verification_for(participant)
        first.save!
      end
      travel_to(Time.zone.local(2026, 11, 15, 23, 30)) do
        duplicate = verification_for(participant)
        assert_not duplicate.save
        assert_includes duplicate.errors[:base], "오늘 이미 인증을 제출하셨습니다."
        assert_equal [first.id], participant.verification_logs.today.pluck(:id)
      end
    end
  end

  test "accepts the next local day even when both submissions share a UTC date" do
    Time.use_zone("Asia/Seoul") do
      participant = nil
      first = nil
      travel_to(Time.zone.local(2026, 11, 15, 23, 30)) do
        participant = build_participant
        first = verification_for(participant)
        first.save!
      end
      travel_to(Time.zone.local(2026, 11, 16, 0, 30)) do
        next_day = verification_for(participant)
        assert next_day.save, next_day.errors.full_messages.join(", ")
        assert_equal first.created_at.utc.to_date, next_day.created_at.utc.to_date
        assert_equal [next_day.id], participant.verification_logs.today.pluck(:id)
      end
    end
  end

  test "daily boundaries follow the selected timezone rather than fixed Seoul time" do
    Time.use_zone("Sydney") do
      participant = nil
      first = nil
      travel_to(Time.zone.local(2026, 11, 15, 23, 30)) do
        participant = build_participant
        first = verification_for(participant)
        first.save!
      end
      travel_to(Time.zone.local(2026, 11, 16, 0, 30)) do
        next_day = verification_for(participant)
        assert next_day.save, next_day.errors.full_messages.join(", ")
        assert_equal first.created_at.in_time_zone("Seoul").to_date, next_day.created_at.in_time_zone("Seoul").to_date
        assert_equal [next_day.id], participant.verification_logs.today.pluck(:id)
      end
    end
  end

  private

  def build_participant
    challenge = Challenge.create!(title: "Synthetic timezone challenge", host: users(:host),
      start_date: Date.current - 1.day, end_date: Date.current + 2.days, mode: :online, cost_type: :free)
    Participant.create!(user: users(:participant), challenge: challenge, joined_at: Time.current)
  end

  def verification_for(participant)
    VerificationLog.new(participant: participant, challenge: participant.challenge,
      verification_type: :simple, value: "Synthetic completion", status: :approved)
  end
end
