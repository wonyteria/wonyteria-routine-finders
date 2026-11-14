require "test_helper"

class ParticipantFixesTest < ActiveSupport::TestCase
  test "max participants validation" do
    host = User.first || User.create!(email: 'host_test@test.com', password: 'password', nickname: 'HostTest')
    user1 = User.second || User.create!(email: 'user1_test@test.com', password: 'password', nickname: 'User1Test')
    user2 = User.third || User.create!(email: 'user2_test@test.com', password: 'password', nickname: 'User2Test')

    challenge = Challenge.create!(
      title: "Bug Fix Test Challenge",
      start_date: Date.current,
      end_date: Date.current + 7.days,
      host: host,
      max_participants: 1,
      status: :active,
      mode: :online,
      cost_type: :free
    )

    p1 = Participant.new(user: user1, challenge: challenge, joined_at: Time.current)
    assert p1.save, "User 1 should join successfully"

    p2 = Participant.new(user: user2, challenge: challenge, joined_at: Time.current)
    assert_not p2.save, "User 2 should NOT be able to join"
    assert_includes p2.errors.full_messages, "모집 정원이 꽉 찼습니다."
  end

  test "one verification per day validation" do
    host = User.first || User.create!(email: 'host_test2@test.com', password: 'password', nickname: 'HostTest2')
    user1 = User.second || User.create!(email: 'user1_test2@test.com', password: 'password', nickname: 'User1Test2')
    
    challenge = Challenge.create!(
      title: "Verification Test Challenge",
      start_date: Date.current,
      end_date: Date.current + 7.days,
      host: host,
      max_participants: 10,
      status: :active,
      mode: :online,
      cost_type: :free
    )
    p1 = Participant.create!(user: user1, challenge: challenge, joined_at: Time.current)

    log1 = VerificationLog.new(participant: p1, challenge: challenge, verification_type: :simple, value: "done", status: :approved)
    assert log1.save, "First log should save"

    log2 = VerificationLog.new(participant: p1, challenge: challenge, verification_type: :simple, value: "done again", status: :pending)
    assert_not log2.save, "Second log should fail"
    assert_includes log2.errors.full_messages, "오늘 이미 인증을 제출하셨습니다."
  end
end
