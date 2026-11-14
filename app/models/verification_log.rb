class VerificationLog < ApplicationRecord
  # Enums
  enum :verification_type, { simple: 0, metric: 1, photo: 2, url: 3, complex: 4 }, prefix: true
  enum :status, { pending: 0, approved: 1, rejected: 2 }

  # Associations
  belongs_to :participant
  belongs_to :challenge

  # Validations
  validates :verification_type, presence: true
  validate :one_verification_per_day, on: :create

  # Scopes
  scope :today, -> { where(created_at: Time.current.all_day) }
  scope :recent, -> { order(created_at: :desc) }

  # Callbacks
  after_save :update_participant_verification, if: :saved_change_to_status?

  # Methods
  def add_reaction!(reaction_type)
    current_reactions = reactions || []
    existing = current_reactions.find { |r| r["type"] == reaction_type }

    if existing
      existing["count"] += 1
    else
      current_reactions << { "type" => reaction_type, "count" => 1 }
    end

    update(reactions: current_reactions)
  end

  private

  def update_participant_verification
    return unless approved?

    # 지연 승인 버그 픽스: 작성 날짜가 '오늘'일 때만 당일 완료 UI 토글 업데이트
    if created_at.to_date == Date.current
      participant.update(today_verified: true)
    end

    # 연속 달성일수(streak)는 어제/과거 소급 승인 시에도 전체 재계산이 필요하므로 항상 호출
    participant.update_streak!
  end

  def one_verification_per_day
    return unless participant && challenge
    today_logs = participant.verification_logs.where(created_at: Time.current.all_day)

    if today_logs.where(status: [ :pending, :approved ]).exists?
      errors.add(:base, "오늘 이미 인증을 제출하셨습니다.")
    elsif !challenge.re_verification_allowed && today_logs.where(status: :rejected).exists?
      errors.add(:base, "이전에 제출한 인증이 반려되었으며, 재인증을 허용하지 않는 챌린지입니다.")
    end
  end

  def calculate_completion_rate
    # 챌린지 전체 기간 기준으로 계산하여 Participant 모델과 로직 통일
    return 0.0 unless challenge.start_date.present? && challenge.end_date.present?

    total_days = (challenge.end_date - challenge.start_date).to_i + 1
    total_days = 1 if total_days < 1

    verified_days = participant.verification_logs.approved.select("DISTINCT DATE(created_at)").count
    ((verified_days.to_f / total_days) * 100).round(1)
  rescue => e
    Rails.logger.error "[VerificationLog] completion rate calculation failed: #{e.message}"
    0.0
  end
end
