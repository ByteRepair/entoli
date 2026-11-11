import "../../app/chat_groups.dart";

export "../../app/chat_groups.dart";

/// The heading pinned chats sit under, ahead of every date group.
const pinnedHeading = "Pinned";

const _months = [
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
];

/// What the Flutter sidebar heads a group with. A month of an earlier year
/// says the year, or August 2025 and August 2026 would read as one.
extension ChatGroupHeading on ChatGroup {
  String headingAt(DateTime now) => switch (period) {
    ChatPeriod.pinned => pinnedHeading,
    ChatPeriod.today => "Today",
    ChatPeriod.yesterday => "Yesterday",
    ChatPeriod.previousWeek => "Previous 7 days",
    ChatPeriod.previousMonth => "Previous 30 days",
    ChatPeriod.month =>
      month!.year == now.toLocal().year
          ? _months[month!.month - 1]
          : "${_months[month!.month - 1]} ${month!.year}",
  };
}
