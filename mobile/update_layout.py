import re

with open('/Users/mohammadshayani/Vibe/mobile/modules/vibe-chat-native/ios/ChatNativeHomeCardCell.swift', 'r') as f:
    code = f.read()

# Change translates = false to true for all manual layout elements
manual_views = [
    "titleLabel", "previewLabel", "timeLabel", "unreadBadge", 
    "muteIconView", "pinIconView", "textContainerView", 
    "metaContainerView", "metaIconContainerView"
]

for view in manual_views:
    code = code.replace(f"{view}.translatesAutoresizingMaskIntoConstraints = false", f"{view}.translatesAutoresizingMaskIntoConstraints = true")

# Remove constraints for textContainerView and metaContainerView and icons from NSLayoutConstraint.activate
# We'll do this carefully with regex.

# Remove textContainerView constraints
code = re.sub(r'\s*textContainerView\.leadingAnchor\.constraint[^,]+,', '', code)
code = re.sub(r'\s*textContainerView\.centerYAnchor\.constraint[^,]+,', '', code)
code = re.sub(r'\s*textContainerView\.trailingAnchor\.constraint\([\s\S]*?constant:\s*-8\s*\),', '', code)

# Remove metaContainerView constraints
code = re.sub(r'\s*metaContainerView\.trailingAnchor\.constraint\([\s\S]*?constant:\s*-16\s*\),', '', code)
code = re.sub(r'\s*metaContainerView\.centerYAnchor\.constraint[^,]+,', '', code)
code = re.sub(r'\s*metaContainerView\.widthAnchor\.constraint[^,]+,', '', code)

# We still need unreadBadge width/height? 
# Wait, unreadBadge width and height were in constraints! But layoutTextAndMetaViews sizes it manually using unreadSize!
# Let's remove unreadBadge constraints
code = re.sub(r'\s*unreadBadge\.widthAnchor\.constraint[^,]+,', '', code)
code = re.sub(r'\s*unreadBadge\.heightAnchor\.constraint[^,]+,', '', code)

# Let's remove muteIconView and pinIconView constraints
code = re.sub(r'\s*muteIconView\.widthAnchor\.constraint[^,]+,', '', code)
code = re.sub(r'\s*muteIconView\.heightAnchor\.constraint[^,]+,', '', code)
code = re.sub(r'\s*pinIconView\.widthAnchor\.constraint[^,]+,', '', code)
code = re.sub(r'\s*pinIconView\.heightAnchor\.constraint[^,]+,', '', code)

with open('/Users/mohammadshayani/Vibe/mobile/modules/vibe-chat-native/ios/ChatNativeHomeCardCell.swift', 'w') as f:
    f.write(code)

