#!/usr/bin/env python3
"""Writes the demo mode's sample chats (demo.json, Models.swift's shapes) into a folder.

    make-demo.py <folder>

Everyone in it is made up. The pictures (Images/) are from Unsplash (free to use under the
Unsplash License). Times are relative to now, so the chat list reads "Today" and "Yesterday".
"""
import hashlib
import json
import os
import shutil
import sys
import time
from datetime import datetime, timedelta

folder = os.path.abspath(sys.argv[1])
images = os.path.join(folder, "Images")
here = os.path.dirname(os.path.abspath(__file__))
shutil.rmtree(folder, ignore_errors=True)
shutil.copytree(os.path.join(here, "Images"), images)

now = datetime.now().replace(second=0, microsecond=0)


def at(days_ago, hour, minute):
    """Milliseconds for a time of day, `days_ago` days back."""
    t = (now - timedelta(days=days_ago)).replace(hour=hour, minute=minute)
    return int(t.timestamp() * 1000)


def ago(minutes):
    return int((now - timedelta(minutes=minutes)).timestamp() * 1000)


def image(name):
    return "file://" + os.path.join(images, name)


ME = "100"
people = {
    ME: ("Alex Morgan", None),
    "201": ("Emma Larsen", "avatar-emma.jpg"),
    "202": ("Noah Fischer", "avatar-noah.jpg"),
    "203": ("Mia Rossi", "avatar-mia.jpg"),
    "204": ("Liam Chen", "avatar-liam.jpg"),
    "205": ("Sofia Novak", "avatar-sofia.jpg"),
    "206": ("Ethan Park", "avatar-ethan.jpg"),
    "207": ("Hannah Weber", "avatar-hannah.jpg"),
    "208": ("Lucas Martin", None),
    "209": ("Olivia Brooks", None),
    "210": ("Daniel Kovacs", None),
    "211": ("Lena Hoffmann", "avatar-plant.jpg"),
    "212": ("Jonas Berg", None),
    "213": ("Grace Kim", None),
}


def person(uid, read=None):
    name, avatar = people[uid]
    p = {"id": uid, "name": name}
    if avatar:
        p["avatarURL"] = image(avatar)
    if read is not None:
        p["readWatermark"] = read
    return p


messages = {}
conversations = []
counter = [0]


def msg(thread, sender, ts, text="", **extra):
    counter[0] += 1
    m = {
        "id": extra.pop("id", f"m{counter[0]}"),
        "threadID": thread,
        "senderID": sender,
        "isFromMe": sender == ME,
        "isSystem": extra.pop("isSystem", False),
        "text": text,
        "timestamp": ts,
        "attachments": extra.pop("attachments", []),
        "reactions": [{"senderID": s, "emoji": e} for s, e in extra.pop("reactions", [])],
        "status": "sent",
        "isUnsent": False,
        "isEdited": extra.pop("isEdited", False),
    }
    m.update(extra)
    messages.setdefault(thread, []).append(m)
    return m


def photo(name, w, h, aid=None):
    path = os.path.join(images, name)
    return {"id": aid or name, "kind": "image", "url": "file://" + path, "localPath": path, "width": w, "height": h}


def chat(cid, name, members, *, group=False, avatar=None, encrypted=False, unread=0, muted=False,
         colors=None, emoji=None, marketplace=False, request=None, custom_name=None, reads=None):
    thread = messages.get(cid, [])
    last = thread[-1] if thread else None
    snippet = ""
    if last:
        snippet = last["text"] or ("sent a photo." if last["attachments"] else "")
    reads = reads or {}
    c = {
        "id": cid,
        "name": name,
        "hasCustomName": custom_name if custom_name is not None else group,
        "snippet": snippet,
        "snippetSenderID": last["senderID"] if last else None,
        "lastActivity": last["timestamp"] if last else ago(60 * 24 * 5),
        "unreadCount": unread,
        "isGroup": group,
        "isEncrypted": encrypted,
        "isMuted": muted,
        "isMarketplace": marketplace,
        "participants": [person(u, reads.get(u)) for u in members],
    }
    if avatar:
        c["avatarURL"] = image(avatar)
    elif not group:
        other = next(u for u in members if u != ME)
        if people[other][1]:
            c["avatarURL"] = image(people[other][1])
    if colors:
        c["bubbleColors"] = colors
    if emoji:
        c["quickEmoji"] = emoji
    if request:
        c["requestList"] = request
    conversations.append(c)
    return c


# --- Emma: the hero chat (photos, a link preview, a reply, tapbacks, read pictures, typing).
E = "201"
msg(E, E, at(1, 19, 42), "Are we still on for Saturday? 🏔️")
cabin = msg(E, ME, at(1, 19, 45), "Yes! Booked the cabin by the lake 🏡")
msg(E, ME, at(1, 19, 45) + 5000, "", attachments=[photo("lake.jpg", 900, 600)], reactions=[(E, "❤️")])
msg(E, E, at(1, 19, 51), "Wow, that view 😍")
msg(E, ME, ago(46), "https://www.nps.gov/yose/planyourvisit/hiking.htm")
msg(E, E, ago(41), "Is it close to the trailhead?",
    replyTo={"messageID": cabin["id"], "senderID": ME, "text": cabin["text"]})
msg(E, ME, ago(38), "10 minutes by car. Mist Trail first?", reactions=[(E, "👍")])
emma_last = msg(E, ME, ago(37), "Leaving at 7:30 sharp", isEdited=True, previousTexts=["Leaving at 8"])

# --- The hiking group: a theme, a poll, tags.
G = "301"
group_members = [ME, "201", "202", "203", "204"]
poll_voters = {"a": ["201", "202", ME], "b": ["204"], "c": ["203", "204"]}
total = len(group_members)
poll = {
    "id": "poll1",
    "question": "Where should we hike on Saturday?",
    "isComplete": True,
    "options": [
        {"id": oid, "text": text, "voteCount": len(poll_voters[oid]),
         "percent": round(100 * len(poll_voters[oid]) / total),
         "voted": ME in poll_voters[oid], "voters": [person(u) for u in poll_voters[oid]]}
        for oid, text in [("a", "Mist Trail"), ("b", "Half Dome"), ("c", "Glacier Point")]
    ],
}
msg(G, "203", at(1, 17, 50), "", attachments=[photo("moraine.jpg", 900, 600)],
    reactions=[("201", "😮"), (ME, "❤️"), ("204", "❤️")])
msg(G, "203", at(1, 17, 51), "Sunrise from last year. Same spot?")
tag = "@Liam Chen are you bringing the tent?"
msg(G, "203", at(1, 18, 20), tag, mentions=[{"offset": 0, "length": len("@Liam Chen"), "userID": "204"}])
msg(G, "204", at(1, 18, 26), "Yep, and the stove 🔥", reactions=[("203", "😆"), ("202", "👍")])
msg(G, "202", ago(95), "Noah Fischer created a poll: Where should we hike on Saturday?", isSystem=True,
    attachments=[{"id": "poll1", "kind": "poll", "poll": poll}])
msg(G, "202", ago(94), "Vote by tonight please 🙏")
msg(G, ME, ago(60), "Mist Trail, obviously 😄", reactions=[("201", "🎉")])
msg(G, "201", ago(12), "See you all at the trailhead 🥾")

# --- Noah: calls and a shared location.
N = "202"
msg(N, N, at(3, 21, 15), "", attachments=[{"id": "c1", "kind": "call", "call": {"isVideo": True, "outcome": "missed"}}])
msg(N, ME, at(3, 21, 40), "Sorry, was at the gym! Call you back in 5")
msg(N, ME, at(3, 21, 47), "", attachments=[{"id": "c2", "kind": "call", "call": {"isVideo": False, "outcome": "ended", "duration": 754}}])
msg(N, N, ago(180), "Here's the trailhead parking",
    attachments=[{"id": "loc1", "kind": "location", "location": {"latitude": 37.7326, "longitude": -119.5578,
                                                                    "name": "Happy Isles Trailhead",
                                                                    "address": "Yosemite Valley, CA"}}])
msg(N, ME, ago(170), "Got it, thanks!", reactions=[(N, "👍")])

# --- Mia: a reel, a file.
M = "203"
msg(M, M, at(2, 12, 30), "", attachments=[{
    "id": "reel1", "kind": "link", "title": "Golden hour at Tunnel View 🌄", "subtitle": "yosemite.trails",
    "source": "Instagram", "previewURL": image("yosemite.jpg"), "width": 900, "height": 600}])
msg(M, M, at(2, 12, 31), "This is going on my wall")
msg(M, ME, at(2, 13, 2), "", attachments=[{"id": "f1", "kind": "file", "filename": "Packing list.pdf",
                                           "mimeType": "application/pdf", "localPath": os.path.join(images, "Packing list.pdf")}])
msg(M, ME, at(2, 13, 2) + 4000, "Made us a packing list")
msg(M, M, ago(250), "Lifesaver 🙌", reactions=[(ME, "❤️")])

# --- More chats for the list.
msg("205", "205", ago(20), "Can't wait to see the photos! 📸")
msg("206", ME, ago(130), "Pizza on Friday? 🍕")
msg("206", "206", ago(125), "", attachments=[photo("pizza.jpg", 900, 1350)])
msg("206", "206", ago(124), "Already ordered 😎")
msg("401", "207", at(1, 9, 5), "Next month: Project Hail Mary 🚀")
msg("402", "208", at(1, 8, 12), "Mom says dinner is at 7 on Sunday")
msg("209", "209", at(2, 17, 40), "Thanks for the recommendation!")
msg("210", ME, at(3, 11, 20), "See you at the conference 👋")
msg("501", "211", at(1, 15, 30), "Yes, it's still available! Pick-up is in the city center.")
msg("501", ME, at(1, 15, 34), "Great, can I come by tomorrow at 6?")
msg("212", "212", ago(300), "Hi! We met at the climbing gym last week 🧗")
msg("213", "213", at(1, 10, 3), "Hey, are you the one selling the camping stove?")

chat(E, "Emma Larsen", [ME, E], encrypted=True, emoji="🥾", reads={E: emma_last["timestamp"]})
chat(G, "Weekend Hiking Crew", group_members, group=True, avatar="avatar-hiking.jpg", unread=1,
     colors=["#FF8A3D", "#E0418C", "#7B3FE4"], emoji="🏔️",
     reads={"201": ago(12), "202": ago(30), "203": ago(50), "204": ago(12)})
chat("205", "Sofia Novak", [ME, "205"], encrypted=True, unread=1)
chat(N, "Noah Fischer", [ME, N], encrypted=True, reads={N: ago(170)})
chat("206", "Ethan Park", [ME, "206"], encrypted=True)
chat(M, "Mia Rossi", [ME, M], encrypted=True, colors=["#1F9D8B"], reads={M: ago(250)})
chat("401", "Book Club 📚", [ME, "207", "209", "203"], group=True, muted=True)
chat("402", "Family", [ME, "208", "210", "207"], group=True, avatar="avatar-family.jpg")
chat("501", "Lena · Succulent in mint pot", [ME, "211"], marketplace=True, custom_name=True, avatar="avatar-plant.jpg")
chat("209", "Olivia Brooks", [ME, "209"], encrypted=True)
chat("210", "Daniel Kovacs", [ME, "210"], encrypted=True)
chat("212", "Jonas Berg", [ME, "212"], request="mayKnow")
chat("213", "Grace Kim", [ME, "213"], request="mayKnow")

# A one-page PDF for the file attachment.
try:
    from PIL import Image, ImageDraw, ImageFont
    page = Image.new("RGB", (612, 792), "white")
    draw = ImageDraw.Draw(page)
    try:
        title = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 64)
        body = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 40)
    except OSError:
        title = body = ImageFont.load_default()
    draw.rectangle((0, 0, 612, 150), fill="#2E7D6B")
    draw.text((50, 45), "Packing list", fill="white", font=title)
    for i, item in enumerate(["Boots", "Rain jacket", "Headlamp", "Water filter", "Snacks", "Sunscreen"]):
        draw.rectangle((50, 200 + i * 90, 84, 234 + i * 90), outline="#2E7D6B", width=4)
        draw.text((110, 196 + i * 90), item, fill="#222", font=body)
    page.save(os.path.join(images, "Packing list.pdf"))
except ImportError:
    pass

# The link's preview, as LinkPreviews caches what LinkPresentation fetched.
url = "https://www.nps.gov/yose/planyourvisit/hiking.htm"
digest = hashlib.sha256(url.encode()).hexdigest()
previews = os.path.join(folder, "linkpreviews")
os.makedirs(previews, exist_ok=True)
shutil.copy(os.path.join(images, "forest.jpg"), os.path.join(previews, digest + ".jpg"))
with open(os.path.join(previews, digest + ".json"), "w") as f:
    json.dump({"title": "Hiking - Yosemite National Park (U.S. National Park Service)", "site": "nps.gov", "hasImage": True}, f)

# The Account menu's accounts (a shared family Mac): their pictures where Accounts keeps them.
from PIL import Image

accounts = [("", "100", "Alex Morgan", "dog.jpg"), ("jamie", "120", "Jamie Morgan", "moraine.jpg"),
            ("sam", "121", "Sam Morgan", "beach.jpg")]
for key, _, _, picture in accounts:
    account_folder = os.path.join(folder, "Accounts", key) if key else folder
    os.makedirs(account_folder, exist_ok=True)
    with Image.open(os.path.join(images, picture)) as source:
        side = min(source.size)
        left, top = (source.width - side) // 2, (source.height - side) // 2
        source.crop((left, top, left + side, top + side)).resize((128, 128)).save(os.path.join(account_folder, "account.png"))

contacts = [person(u) for u in people if u != ME]
presence = [{"userID": E, "isOnline": True, "lastSeen": 0}, {"userID": M, "isOnline": False, "lastSeen": ago(25)}]
# 1:1 chats' presence is keyed by thread ID (the other person's ID).
conversations.sort(key=lambda c: -c["lastActivity"])
with open(os.path.join(folder, "demo.json"), "w") as f:
    json.dump({"account": {"id": ME, "name": people[ME][0]}, "conversations": conversations,
               "messages": messages, "contacts": contacts, "presence": presence,
               "accounts": [{"key": k, "userID": u, "name": n} for k, u, n, _ in accounts]},
              f, ensure_ascii=False, indent=1)
print(folder)
