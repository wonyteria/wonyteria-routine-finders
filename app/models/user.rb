# frozen_string_literal: true

# == User Model
#
# 루틴 파인더스의 핵심 사용자 모델
# OAuth 인증을 통해 생성되며, 루틴 관리, 챌린지 참여, 루파 클럽 멤버십 등의 기능을 제공합니다.
#
# === Attributes
# * +email+ - 사용자 이메일 (unique, required)
# * +nickname+ - 사용자 닉네임 (required)
# * +provider+ - OAuth 제공자 (kakao, google, threads)
# * +uid+ - OAuth 제공자의 사용자 고유 ID
# * +role+ - 사용자 권한 (user, club_admin, super_admin)
# * +total_routine_completions+ - 총 루틴 완료 횟수 (레벨 계산에 사용)
# * +profile_image+ - 프로필 이미지 URL (레거시, avatar로 대체 중)
# * +bio+ - 사용자 소개
#
# === Associations
# * has_many :hosted_challenges - 개설한 챌린지
# * has_many :participations - 참여 중인 챌린지
# * has_many :personal_routines - 개인 루틴
# * has_many :routine_club_members - 루파 클럽 멤버십
# * has_many :user_badges - 획득한 배지
# * has_many :notifications - 알림
#
# === Level System
# 레벨은 루틴·챌린지·커뮤니티 활동 점수와 LEVEL_THRESHOLDS로 계산됩니다.
# 예: 루틴 50회 완료만 있는 사용자는 500점으로 레벨 3입니다.
#
class User < ApplicationRecord
  after_initialize :set_default_preferences, if: :new_record?

  def set_default_preferences
    self.notification_preferences ||= {
      morning_affirmation: true,
      evening_reminder: true,
      night_check: true,
      club_status: true,
      club_operations: true,
      community: true,
      achievements: true
    }
  end
  def notification_enabled?(pref_key)
    prefs = self.notification_preferences || {}
    prefs[pref_key.to_s] != false && prefs[pref_key.to_sym] != false
  end

  has_secure_password
  has_one_attached :avatar

  # 통합 프로필 이미지 호출 메서드 (ActiveStorage 우선)
  def profile_image
    if avatar.attached?
      begin
        # Variant를 사용하여 최적화된 크기로 반환
        Rails.application.routes.url_helpers.rails_representation_url(
          avatar.variant(resize_to_fill: [ 300, 300 ]),
          only_path: true
        )
      rescue => e
        Rails.logger.error "Avatar representation failed for User #{id}: #{e.message}"
        # 에러 시 원본 또는 레거시 컬럼 반환
        read_attribute(:profile_image).presence || default_avatar_url
      end
    else
      # 레거시 컬럼 또는 기본 아바타 반환
      read_attribute(:profile_image).presence || default_avatar_url
    end
  end

  def default_avatar_url
    "https://api.dicebear.com/7.x/avataaars/svg?seed=#{id}"
  end

  # Enums
  # Role hierarchy: user (0) < club_admin (1) < super_admin (2)
  # - user: Regular platform user
  # - club_admin: Can manage assigned routine clubs
  # - super_admin: Full platform access, can assign club admins
  enum :role, { user: 0, club_admin: 1, super_admin: 2 }
  scope :admin, -> { where(role: [ :club_admin, :super_admin ]) }

  after_save :ensure_rufa_club_membership_for_admin
  after_create :notify_admins_of_new_signup

  def notify_admins_of_new_signup
    # 신규 가입 시 마스터 권한에게 알림
    User.where(role: :super_admin).find_each do |admin|
      admin.notifications.create!(
        notification_type: :system,
        title: "🎉 신규 회원 가입",
        content: "#{nickname}님이 루틴 파인더스에 가입했습니다.",
        link: "/admin_center"
      )
    end
  rescue => e
    Rails.logger.error "Failed to notify admins of new signup: #{e.message}"
  end

  def ensure_rufa_club_membership_for_admin
    return unless admin?

    # 공식 클럽 찾기 (없으면 보장)
    official_club = RoutineClub.official.first || RoutineClub.ensure_official_club
    return unless official_club

    # 이미 멤버십이 있는지 확인하고 없으면 생성
    begin
      member = routine_club_members.find_or_initialize_by(routine_club: official_club)

      if member.changed? || member.new_record?
        # Admin은 항상 Active Confirmed 상태 유지
        member.status = :active
        member.payment_status = :confirmed
        member.membership_start_date ||= official_club.start_date
        member.membership_end_date ||= official_club.end_date
        member.depositor_name ||= (nickname.presence || "Admin-#{id}")
        member.contact_info ||= (phone_number.presence || "Admin-Contact")
        member.goal ||= "관리자로서 루파 클럽을 운영하고 리딩합니다."
        member.is_moderator = true
        member.paid_amount ||= 0

        unless member.save
          Rails.logger.error "Admin membership auto-update failed for User #{id}: #{member.errors.full_messages.join(', ')}"
        end
      end
    rescue => e
      Rails.logger.error "Error in ensure_rufa_club_membership_for_admin for User #{id}: #{e.message}"
    end
  end

  # Backward compatibility: admin? returns true for both club_admin and super_admin
  def admin?
    club_admin? || super_admin?
  end

  # 호스트 여부 확인 (챌린지 또는 루파 클럽을 개설한 사용자)
  def host?
    club_admin? || hosted_challenges.exists? || hosted_routine_clubs.exists?
  end

  # Associations
  has_many :hosted_challenges, class_name: "Challenge", foreign_key: :host_id, dependent: :destroy
  has_many :participations, class_name: "Participant", dependent: :destroy
  has_many :challenges, through: :participations
  has_many :personal_routines, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :staffs, dependent: :destroy
  has_many :challenge_applications, dependent: :destroy
  has_many :user_badges, dependent: :destroy
  has_many :badges, through: :user_badges
  has_many :user_goals, dependent: :destroy
  has_many :reviews, dependent: :destroy

  # Routine Clubs
  has_many :hosted_routine_clubs, class_name: "RoutineClub", foreign_key: :host_id
  has_many :routine_club_members, dependent: :destroy
  has_many :routine_clubs, through: :routine_club_members
  has_many :routine_club_reports, dependent: :destroy
  has_many :rufa_activities, dependent: :destroy
  has_many :web_push_subscriptions, dependent: :destroy

  # Validations
  validates :nickname, presence: true

  # 이메일: 탈퇴한 유저는 중복 검사에서 제외, 임시 이메일(.temp)은 포맷 검사 제외
  validates :email, presence: true
  validates :email, uniqueness: { conditions: -> { where(deleted_at: nil) } }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, unless: -> { email.to_s.end_with?(".temp") }

  # 비밀번호: 소셜 로그인 유저를 위해 nil 허용, 변경 시나 신규 생성 시에만 검사
  validates :password, length: { minimum: 8 }, allow_nil: true, if: -> { new_record? || will_save_change_to_password_digest? }
  validates :password, presence: true, on: :create, if: -> { provider.blank? }

  # Soft delete scopes
  scope :active, -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }

  def suspended?
    suspended_at.present? && deleted_at.blank?
  end

  def deleted?
    deleted_at.present?
  end

  def active_status
    if deleted?
      "withdrawn"
    elsif suspended?
      "suspended"
    else
      "active"
    end
  end

  def soft_delete
    update(deleted_at: Time.current)
  end

  def restore
    update(deleted_at: nil)
  end

  def self.from_omniauth(auth)
    return nil if auth.nil?

    Rails.logger.info "OmniAuth: Processing #{auth.provider} login for uid: #{auth.uid}"

    # Safely extract info
    info = auth.info || {}
    email = info.email
    name = info.name
    nickname = info.nickname
    image = info.image

    Rails.logger.info "OmniAuth: Received data - email: #{email}, name: #{name}, nickname: #{nickname}"

    # 1. First, try to find existing user by provider and uid (including deleted accounts)
    user = unscoped.where(provider: auth.provider, uid: auth.uid).first

    # 2. Check if user was deleted
    if user&.deleted?
      Rails.logger.info "OmniAuth: Found deleted account for #{auth.provider}"
      # Return the deleted user - SessionsController will handle the restoration flow
      return user
    end

    # 3. If not found, try to find by email to link accounts (if email is provided)
    if user.nil? && email.present?
      user = active.find_by(email: email)
      if user
        Rails.logger.info "OmniAuth: Linking existing user ID: #{user.id}, Nickname: #{user.nickname} with #{auth.provider} (UID: #{auth.uid})"
        user.update(provider: auth.provider, uid: auth.uid)
      else
        Rails.logger.info "OmniAuth: No existing active user found with email: #{email}. Will create a new account."
      end
    end

    # 4. If still nil, create new user
    if user.nil?
      Rails.logger.info "OmniAuth: Creating new user for #{auth.provider}"
      user = new do |u|
        u.provider = auth.provider
        u.uid = auth.uid
        u.email = email.presence || "#{auth.provider}-#{auth.uid}@routinefinders.temp"
        # Truncate nickname/name to 255 chars to prevent DB overflow
        raw_nickname = name.presence || nickname.presence || "#{auth.provider.to_s.titleize} User #{auth.uid.to_s.last(4)}"
        u.nickname = raw_nickname.slice(0, 250)
        # Truncate image URL to 255 chars (DB string limit)
        u.profile_image = image.to_s.slice(0, 250) if image.present?
        u.password = SecureRandom.hex(16)
      end
    end

    # 5. Update tokens (threads specific for now as we have specific columns)
    if user && auth.provider == "threads" && auth.credentials
      user.threads_token = auth.credentials.token
      user.threads_refresh_token = auth.credentials.refresh_token
      user.threads_expires_at = Time.at(auth.credentials.expires_at) if auth.credentials&.expires_at
    end

    if user
      if user.new_record? || user.changed?
        unless user.save
          Rails.logger.error "OmniAuth: Failed to save user for #{auth.provider}"
          Rails.logger.error "OmniAuth: Validation errors: #{user.errors.full_messages.join(', ')}"
        else
          Rails.logger.info "OmniAuth: Successfully saved user #{user.id} for #{auth.provider}"
        end
      end
    end

    user
  end

  # Wallet methods
  def wallet
    { balance: wallet_balance, total_refunded: total_refunded }
  end

  def participant_stats
    {
      ongoing_count: ongoing_count,
      completed_count: completed_count,
      avg_completion_rate: avg_completion_rate
    }
  end

  def ongoing_count
    participations.where(status: :ongoing).count
  end

  def completed_count
    participations.where(status: :completed).count
  end

  def avg_completion_rate
    return 0 if participations.empty?
    participations.average(:completion_rate).to_f.round(1)
  end

  def host_stats
    return nil unless hosted_challenges.exists?
    {
      total_participants: host_total_participants,
      avg_completion_rate: host_avg_completion_rate,
      completed_challenges: host_completed_challenges
    }
  end

  def host_total_participants
    Participant.where(challenge_id: hosted_challenges.pluck(:id)).count
  end

  def host_avg_completion_rate
    return 0 if hosted_challenges.empty?
    Participant.where(challenge_id: hosted_challenges.pluck(:id)).average(:completion_rate).to_f.round(1)
  end

  def host_completed_challenges
    hosted_challenges.where(status: :completed).count
  end

  def unread_notifications_count
    notifications.where(is_read: false).count
  end

  def profile_image
    if avatar.attached?
      Rails.application.routes.url_helpers.rails_blob_url(avatar, only_path: true)
    else
      self[:profile_image].presence || "https://api.dicebear.com/7.x/lorelei/svg?seed=#{id}&backgroundColor=b6e3f4,c0aede,d1d4f9,ffd5dc,ffdfbf"
    end
  end

  # SNS Links accessors
  def instagram
    sns_links&.dig("instagram")
  end

  def threads
    sns_links&.dig("threads")
  end

  def blog
    sns_links&.dig("blog")
  end

  def youtube
    sns_links&.dig("youtube")
  end

  def twitter
    sns_links&.dig("twitter")
  end

  # Saved account info
  def saved_account
    return nil if saved_bank_name.blank?
    {
      bank_name: saved_bank_name,
      account_number: saved_account_number,
      account_holder: saved_account_holder
    }
  end

  def has_saved_account?
    saved_bank_name.present? && saved_account_number.present?
  end

  # Rufa Club Standards
  def is_rufa_club_member?
    # Admins are treated as honorary members
    return true if admin?

    # Everyone else must have a confirmed payment and active status
    # Date constraint removed to allow continuous membership for active members
    routine_club_members.where(status: [ :active, :warned ])
                       .where(payment_status: :confirmed)
                       .exists?
  end

  # 특정 날짜 기준으로 루파 클럽 멤버였는지 확인
  def is_rufa_club_member_on?(date)
    return true if admin?

    # For historical checks, we still verify if they were members during that period
    routine_club_members.where(status: [ :active, :warned ])
                       .where(payment_status: :confirmed)
                       .where("membership_start_date <= ? AND membership_end_date >= ?", date, date)
                       .exists?
  end

  def exclude_rufa_promotions?
    return true if admin?
    routine_club_members.where(status: [ :active, :warned ], payment_status: [ :confirmed, :pending ]).exists?
  end

  def has_active_rufa_membership?
    return true if admin?
    # Active/Warned and Confirmed is enough for ongoing membership
    routine_club_members.where(status: [ :active, :warned ], payment_status: :confirmed).exists?
  end

  def pending_rufa_membership
    routine_club_members.where(status: [ :active, :warned ], payment_status: :confirmed)
                       .where("membership_start_date > ?", Date.current)
                       .order(membership_start_date: :asc)
                       .first
  end

  def is_rufa_pending?
    routine_club_members.where(payment_status: :pending).exists?
  end

  # ① 루틴 작성률 (해당 월 동안 루틴을 기록한 날이 전체의 70% 이상)
  # '기록'의 정의: 해당 일자에 완료 기록이 있거나 루틴이 설정되어 있었던 상태 (여기선 실제 액션 기준)
  def monthly_routine_log_rate(date = Date.current)
    start_date = date.beginning_of_month
    end_date = [ date.end_of_month, Date.current ].min
    # 해당 기간 내에 실제로 루틴이 설정되어 있었던 날의 수(target_days)를 계산
    active_routines = personal_routines.where(deleted_at: nil).to_a
    target_days = 0

    (start_date..end_date).each do |d|
      has_routine = active_routines.any? do |r|
        next false if r.created_at.to_date > d

        days_list = r.days
        if days_list.is_a?(String)
          begin
            days_list = JSON.parse(days_list)
          rescue JSON::ParserError
            days_list = []
          end
        end
        (days_list || []).map(&:to_s).include?(d.wday.to_s)
      end

      target_days += 1 if has_routine
    end

    return 0 if target_days <= 0

    # 해당 월에 완료 기록이 있는 고유한 날짜 수
    logged_days = personal_routines.joins(:completions)
                                  .where(personal_routine_completions: { completed_on: start_date..end_date })
                                  .distinct
                                  .count("personal_routine_completions.completed_on")

    # 분자가 분모보다 클 수 없도록 조정
    logged_days = [ logged_days, target_days ].min

    (logged_days.to_f / target_days * 100).round(1)
  end

  # ② 루틴 달성률 (작성한 루틴 중 하루에 하나 이상 실천한 날 기준 70% 이상)
  def monthly_achievement_rate(date = Date.current)
    start_date = date.beginning_of_month
    end_date = [ date.end_of_month, Date.current ].min
    period_routine_rate(start_date, end_date)
  end

  def daily_achievement_rate(date = Date.current)
    # [수정] 삭제된 루틴은 아예 통계에서 제외 (User Request: "삭제한 루틴은 아예 삭제가 되어야 해")
    # 따라서 과거 기록에서도 삭제된 루틴은 없던 것으로 간주함.

    # 현재 활성화된(삭제되지 않은) 루틴만 조회
    all_routines = personal_routines.where(deleted_at: nil)

    # 루틴 활성 여부 확인

    todays_active_routines = all_routines.select do |r|
      # [수정] 클럽 멤버 여부와 상관없이, 실제 루틴이 생성된 날 이후부터만 달성률 계산에 포함
      created_condition = r.created_at.to_date <= date

      days_list = r.days
      if days_list.is_a?(String)
        begin
          days_list = JSON.parse(days_list)
        rescue JSON::ParserError
          days_list = []
        end
      end
      day_condition = (days_list || []).map(&:to_s).include?(date.wday.to_s)

      created_condition && day_condition
    end

    total_count = todays_active_routines.size
    return 0 if total_count.zero?

    # 분자 계산 (완료 기록 조회)
    completed_count = PersonalRoutineCompletion
                        .where(personal_routine_id: todays_active_routines.map(&:id))
                        .where(completed_on: date)
                        .count

    (completed_count.to_f / total_count * 100).round(1)
  end

  def period_routine_rate(start_date, end_date)
    # [수정] 삭제된 루틴은 아예 통계에서 제외
    all_routines = personal_routines.where(deleted_at: nil)

    # to_a로 미리 로드하여 DB 쿼리 최소화
    loaded_routines = all_routines.to_a

    # 루파 클럽 멤버십 기간 확인 (N+1 방지)
    total_required = 0
    (start_date..end_date).each do |date|
      # 해당 날짜에 루파 클럽 멤버였는지 확인 (로깅/디버깅 필요시 유지)

      # 해당 날짜(date)에 설정되어 있던 루틴 합산
      active_count_for_day = loaded_routines.count do |r|
        # [수정] 루파 클럽 멤버십 여부보다 실제 데이터 생성 시점이 우선됨 (소급 적용 방지)
        created_condition = r.created_at.to_date <= date

        days_list = r.days
        if days_list.is_a?(String)
          begin
            days_list = JSON.parse(days_list)
          rescue JSON::ParserError
            days_list = []
          end
        end
        day_condition = (days_list || []).map(&:to_s).include?(date.wday.to_s)

        created_condition && day_condition
      end
      total_required += active_count_for_day
    end

    return 0.0 if total_required == 0

    # 완료 기록도 삭제되지 않은 루틴들 것만 집계됨 (join 사용 시)
    completed_count = personal_routines.where(deleted_at: nil)
                                      .joins(:completions)
                                      .where(personal_routine_completions: { completed_on: start_date..end_date })
                                      .count

    (completed_count.to_f / total_required * 100).round(1)
  end

  def all_routines_completed?(date = Date.current)
    # unscoped 사용
    all_routines = personal_routines.try(:unscoped) || personal_routines

    todays_active_routines = all_routines.select do |r|
      days_list = r.days
      if days_list.is_a?(String)
        begin
          days_list = JSON.parse(days_list)
        rescue JSON::ParserError
          days_list = []
        end
      end

      created_condition = r.created_at.to_date <= date
      deleted_condition = r.deleted_at.nil? || r.deleted_at.to_date > date
      day_condition = (days_list || []).map(&:to_s).include?(date.wday.to_s)

      created_condition && deleted_condition && day_condition
    end

    return false if todays_active_routines.empty?

    completed_count = personal_routines.joins(:completions)
                                      .where(personal_routine_completions: { completed_on: date })
                                      .count
    completed_count >= todays_active_routines.size
  end

  def rufa_club_score(date = Date.current)
    # 신규 게이미피케이션 RP 시스템으로 랭킹 산정 기준 통일
    monthly_routine_points(date)
  end

  # 누적 통계 (All-time)
  def total_routine_completions
    # 루파 클럽 가입 이후 총 루틴 완료 횟수
    membership = routine_club_members.confirmed.active.first
    return 0 unless membership

    join_date = membership.joined_at.to_date
    personal_routines.joins(:completions)
                    .where("personal_routine_completions.completed_on >= ?", join_date)
                    .count
  end

  def rufa_member_days
    # 루파 클럽 멤버로 활동한 일수
    membership = routine_club_members.confirmed.active.first
    return 0 unless membership && membership.joined_at

    (Date.current - membership.joined_at.to_date).to_i + 1
  end

  def lifetime_rufa_score
    # 누적 점수: 총 완료 횟수 기반
    total_routine_completions
  end

  def monthly_routine_points(date = Date.current)
    start_date = date.beginning_of_month
    end_date = [date.end_of_month, Date.current].min

    routine_count = personal_routines.joins(:completions)
                                     .where(personal_routine_completions: { completed_on: start_date..end_date })
                                     .count
                                     
    # 루틴 1회 완료 = 10 RP
    routine_count * 10
  end

  def current_growth_identity(date = Date.current)
    ach_rate = monthly_achievement_rate(date)
    rp = monthly_routine_points(date)

    if rp >= 3000 && ach_rate >= 85
      "루파 로드 마스터"
    elsif rp >= 1500 && ach_rate >= 70
      "정진하는 가이드"
    elsif rp >= 500
      "성장의 개척자"
    else
      "시작하는 루파"
    end
  end

  def daily_greeting_info
    current_wday = Date.current.wday.to_s
    todays_routines = personal_routines.where(deleted_at: nil).select { |r| (r.days || []).map(&:to_s).include?(current_wday) }
    completed_today = personal_routines.joins(:completions).where(personal_routine_completions: { completed_on: Date.current }).count

    rate = todays_routines.any? ? (completed_today.to_f / todays_routines.size * 100).round : 0

    message = case
    when todays_routines.empty?
                "오늘은 아직 설정된 루틴이 없네요! 나만의 목표를 세워볼까요? ✨"
    when completed_today == 0
                "기분 좋은 시작을 위해 첫 번째 루틴을 체크해 보세요! 🔥"
    when rate >= 100
                "와우! 오늘의 모든 루틴을 완수하셨군요! 정말 멋져요 🚀"
    when rate >= 50
                "절반이나 왔어요! 남은 루틴도 차근차근 해내실 거라 믿어요 💪"
    else
                "하나씩 해내다 보면 어느새 목표에 닿을 거예요. 화이팅! 🌱"
    end

    {
      total: todays_routines.size,
      completed: completed_today,
      rate: rate,
      message: message,
      identity: current_growth_identity,
      level: calculate_level
    }
  end

  def category_stats(start_date = nil, end_date = nil)
    # 날짜 범위가 주어지지 않으면 전체 기간(Lifetime) 통계를 반환
    query = personal_routines.joins(:completions)
    query = query.where(personal_routine_completions: { completed_on: start_date..end_date }) if start_date && end_date

    stats = query.group(:category).count

    categories = [ "HEALTH", "LIFE", "MIND", "STUDY", "HOBBY", "MONEY" ]
    categories.each { |cat| stats[cat] ||= 0 }
    stats
  end

  def category_routine_history
    # 카테고리별로 실제 완료 기록이 있는 루틴 제목 목록 추출 (삭제된 루틴 포함)
    personal_routines.unscoped
                     .where(user_id: id)
                     .joins(:completions)
                     .select("personal_routines.category, personal_routines.title")
                     .distinct
                     .each_with_object({}) do |r, hash|
                       hash[r.category] ||= []
                       # 제목 중복 제거 및 추가
                       hash[r.category] << r.title unless hash[r.category].include?(r.title)
                     end
  end

  # 카테고리별 성취 기반 아이덴티티 타이틀 결정
  def category_identity_title(category)
    count = category_stats[category] || 0
    case
    when count >= 100 then "#{category_label(category)} 마스터"
    when count >= 50  then "#{category_label(category)} 전문가"
    when count >= 20  then "#{category_label(category)} 매니아"
    when count >= 5   then "#{category_label(category)} 입문자"
    else "#{category_label(category)} 시작"
    end
  end

  def category_label(category)
    {
      "HEALTH" => "건강/운동",
      "LIFE" => "생활/일기",
      "MIND" => "마음챙김",
      "STUDY" => "학습/성장",
      "HOBBY" => "취미/여가",
      "MONEY" => "자산/금융"
    }[category] || "기타"
  end


  # Comprehensive Level System
  # Level increases based on total platform activity score

  # Activity point configuration
  ACTIVITY_POINTS = {
    routine_completion: 10,      # 루틴 1회 완료
    feed_post: 5,                # 오늘의 확언 작성
    live_participation: 20,      # 라이브룸 참여
    challenge_hosting: 60,       # 챌린지/모임 개설 (밸런스 조정: 100 -> 60)
    challenge_participation: 30  # 챌린지/모임 참여 (밸런스 조정: 50 -> 30)
  }.freeze

  # Level thresholds (비선형 성장)
  LEVEL_THRESHOLDS = [
    { level: 1, min_score: 0 },
    { level: 2, min_score: 100 },
    { level: 3, min_score: 300 },
    { level: 4, min_score: 600 },
    { level: 5, min_score: 1000 },
    { level: 6, min_score: 1500 },
    { level: 7, min_score: 2100 },
    { level: 8, min_score: 2800 },
    { level: 9, min_score: 3600 },
    { level: 10, min_score: 4500 }
  ].freeze

  def total_platform_score
    score = 0

    # 1. 루틴 활동
    score += total_routine_completions * ACTIVITY_POINTS[:routine_completion]

    # 2. 챌린지 및 모임 활동 (참여만 해도 점수 지급)
    score += participations.count * ACTIVITY_POINTS[:challenge_participation]
    score += hosted_challenges.count * ACTIVITY_POINTS[:challenge_hosting]

    # 3. 커뮤니티 활동 (확언 작성 등)
    # activity_type: 'reflection' 인 것만 확언 작성으로 간주
    score += rufa_activities.where(activity_type: "reflection").count * ACTIVITY_POINTS[:feed_post]

    # 4. 라이브룸 참여 (Activity 테이블에 live_join 타입이 있다고 가정하거나 추가 구현 필요)
    # 현재는 placeholder 로직: rufa_activities 중 type이 'live_join'인 것
    score += rufa_activities.where(activity_type: "live_join").count * ACTIVITY_POINTS[:live_participation]

    score
  end

  # 특정 월의 활동 점수 계산
  def monthly_platform_score(target_date = Date.current)
    start_date = target_date.beginning_of_month
    end_date = target_date.end_of_month
    range = start_date..end_date

    score = 0

    # 1. 루틴 활동 (해당 기간 내 완료)
    score += personal_routines.joins(:completions)
                              .where(personal_routine_completions: { completed_on: range })
                              .count * ACTIVITY_POINTS[:routine_completion]

    # 2. 챌린지/모임 참여 (해당 기간 내 참여)
    score += participations.where(created_at: range).count * ACTIVITY_POINTS[:challenge_participation]
    score += hosted_challenges.where(created_at: range).count * ACTIVITY_POINTS[:challenge_hosting]

    # 3. 커뮤니티 활동 (확언, 라이브 등)
    score += rufa_activities.where(created_at: range, activity_type: "reflection").count * ACTIVITY_POINTS[:feed_post]
    score += rufa_activities.where(created_at: range, activity_type: "live_join").count * ACTIVITY_POINTS[:live_participation]

    score
  end

  def total_routine_completions
    # 모든 유저: 전체 루틴 완료 횟수
    personal_routines.joins(:completions).count
  end

  def calculate_level
    score = total_platform_score

    # 레벨 10 이하는 테이블 참조
    threshold = LEVEL_THRESHOLDS.reverse.find { |t| score >= t[:min_score] }
    return threshold[:level] if threshold && threshold[:level] <= 10

    # 레벨 11 이상: 4500점 이후 500점씩 증가
    if score >= 4500
      level = 10 + ((score - 4500) / 500)
      [ level, 99 ].min
    else
      1
    end
  end

  def update_level!
    new_level = calculate_level
    if new_level != level
      old_level = level
      update_column(:level, new_level)

      { leveled_up: new_level > old_level, old_level: old_level, new_level: new_level }
    else
      { leveled_up: false, old_level: level, new_level: level }
    end
  end

  def level_progress
    current_score = total_platform_score
    current_level_threshold = LEVEL_THRESHOLDS.find { |t| t[:level] == level }&.dig(:min_score) || 0

    if level < 10
      next_level_threshold = LEVEL_THRESHOLDS.find { |t| t[:level] == level + 1 }&.dig(:min_score) || (current_level_threshold + 500)
    else
      next_level_threshold = current_level_threshold + 500
    end

    score_in_level = current_score - current_level_threshold
    score_needed = next_level_threshold - current_level_threshold

    ((score_in_level.to_f / score_needed) * 100).round
  end

  def score_to_next_level
    current_score = total_platform_score
    current_level_threshold = LEVEL_THRESHOLDS.find { |t| t[:level] == level }&.dig(:min_score) || 0

    if level < 10
      next_level_threshold = LEVEL_THRESHOLDS.find { |t| t[:level] == level + 1 }&.dig(:min_score) || (current_level_threshold + 500)
    else
      next_level_threshold = current_level_threshold + 500
    end

    next_level_threshold - current_score
  end

  def current_month_points
    if is_rufa_club_member?
      rufa_club_score.round(1)
    else
      personal_routines.joins(:completions)
                      .where(personal_routine_completions: {
                        completed_on: Date.current.beginning_of_month..Date.current
                      })
                      .count
    end
  end
end
