class ReactionModel {
  final String id;
  final String parentId;
  final String content;
  final String author;
  final String authorName;
  final String authorProfileImage;
  final DateTime timestamp;

  ReactionModel({
    required this.id,
    required this.parentId,
    required this.content,
    required this.author,
    required this.authorName,
    required this.authorProfileImage,
    required this.timestamp,
  });

  factory ReactionModel.fromEvent(Map<String, dynamic> eventData, Map<String, String> authorProfile) {
    String parentId = '';
    for (var tag in eventData['tags']) {
      if (tag.length >= 2 && tag[0] == 'e') {
        parentId = tag[1];
        break;
      }
    }

    return ReactionModel(
      id: eventData['id'] as String,
      parentId: parentId,
      content: eventData['content'] as String? ?? '',
      author: eventData['pubkey'] as String,
      authorName: authorProfile['name'] ?? 'Anonymous',
      authorProfileImage: authorProfile['profileImage'] ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch((eventData['created_at'] as int) * 1000),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'parentId': parentId,
      'content': content,
      'author': author,
      'authorName': authorName,
      'authorProfileImage': authorProfileImage,
      'timestamp': timestamp.millisecondsSinceEpoch ~/ 1000,
    };
  }
}
