require "test_helper"

class UserTest < ActiveSupport::TestCase
  def setup
    @user = User.new(
      email: "test@example.com",
      nickname: "테스트유저",
      provider: "kakao",
      uid: "12345",
      password: "password123"
    )
  end

  test "should be valid with valid attributes" do
    assert @user.valid?
  end

  test "should require email" do
    @user.email = nil
    assert_not @user.valid?
    assert @user.errors.of_kind?(:email, :blank)
  end

  test "should require nickname" do
    @user.nickname = nil
    assert_not @user.valid?
    assert @user.errors.of_kind?(:nickname, :blank)
  end

  test "email should be unique" do
    duplicate_user = @user.dup
    @user.save!
    assert_not duplicate_user.valid?
  end

  test "should calculate level correctly" do
    @user.save!
    routine = @user.personal_routines.create!(title: "Synthetic scoring routine", days: ["mon"])
    routine.completions.insert_all!(50.times.map { |n| { completed_on: Date.current - n.days } })

    assert_equal 50, @user.reload.total_routine_completions
    assert_equal 3, @user.calculate_level
    @user.update_level!
    assert_equal 3, @user.reload.level
  end

  test "should have many personal routines" do
    user = users(:host)
    assert_respond_to user, :personal_routines
  end

  test "should have many participations" do
    user = users(:host)
    assert_respond_to user, :participations
  end

  test "should have profile image" do
    user = users(:host)
    assert_respond_to user, :profile_image
  end

  test "admin? should return false for regular user" do
    assert_not @user.admin?
  end

  test "super_admin? should return false for regular user" do
    assert_not @user.super_admin?
  end
end
