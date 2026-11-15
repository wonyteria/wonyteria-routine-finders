require "test_helper"

class ChallengeTest < ActiveSupport::TestCase
  def setup
    @user = users(:host)
    @challenge = Challenge.new(
      title: "30일 독서 챌린지",
      description: "매일 30분 독서하기",
      host: @user,
      start_date: Date.current,
      end_date: Date.current + 30.days,
      recruitment_end_date: Date.current + 7.days,
      cost_type: :free,
      max_participants: 30
    )
  end

  test "should be valid with valid attributes" do
    assert @challenge.valid?
  end

  test "should require title" do
    @challenge.title = nil
    assert_not @challenge.valid?
  end

  test "should require start_date" do
    @challenge.start_date = nil
    assert_not @challenge.valid?
  end

  test "should require end_date" do
    @challenge.end_date = nil
    assert_not @challenge.valid?
  end

  test "end_date should be after start_date" do
    @challenge.end_date = @challenge.start_date - 1.day
    assert_not @challenge.valid?
  end

  test "should have host" do
    @challenge.host = nil
    assert_not @challenge.valid?
  end

  test "should have many participants" do
    challenge = challenges(:free_challenge)
    assert_respond_to challenge, :participants
  end

  test "should allow a single-day challenge" do
    @challenge.end_date = @challenge.start_date
    assert @challenge.valid?, @challenge.errors.full_messages.join(", ")
  end

  test "offline? follows mode rather than meeting type" do
    @challenge.meeting_type = :single
    assert_not @challenge.offline?
    @challenge.mode = :offline
    assert @challenge.offline?
  end

  test "cost_type_free? should return true for free challenges" do
    @challenge.cost_type = :free
    assert @challenge.cost_type_free?
  end

  test "should increment current_participants" do
    challenge = challenges(:free_challenge)
    initial_count = challenge.current_participants
    challenge.increment!(:current_participants)
    assert_equal initial_count + 1, challenge.reload.current_participants
  end
end
