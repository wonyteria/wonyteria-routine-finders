require "test_helper"

class ProfilesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = users(:participant)
  end

  def login_as(user)
    post login_path, params: { email: user.email, password: "password123" }
  end

  test "should redirect show to login when not authenticated" do
    get profile_path
    assert_redirected_to prototype_login_path
  end

  test "should get show when authenticated" do
    assert badges(:one).valid?
    assert_nil badges(:one).icon_path
    login_as(@user)
    get profile_path
    assert_response :success
    assert_select "p", text: rufa_activities(:two).body
    assert_select "span.text-5xl", text: "🏅"
  end

  test "should redirect edit to login when not authenticated" do
    get edit_profile_path
    assert_redirected_to prototype_login_path
  end

  test "should get edit when authenticated" do
    login_as(@user)
    get edit_profile_path
    assert_response :success
  end

  test "should update profile with valid params" do
    login_as(@user)

    patch profile_path, params: {
      user: {
        bio: "New bio text",
        saved_bank_name: "카카오뱅크",
        saved_account_number: "3333123456789",
        saved_account_holder: "테스트",
        sns_links: {
          instagram: "myinstagram",
          threads: "mythreads"
        }
      }
    }

    assert_redirected_to profile_path
    @user.reload
    assert_equal "New bio text", @user.bio
    assert_equal "카카오뱅크", @user.saved_bank_name
    assert_equal "myinstagram", @user.sns_links["instagram"]
  end
end
