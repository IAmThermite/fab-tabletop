# Flesh and Blood Tabletop

FaB Tabletop is where Flesh and Blood players can come together online and play against each other from the comfort of their homes using their webcam.

## How it works

Players create a game and use their webcam to look at their cards. The app uses WebRTC to connect players to one another with STUN and TURN fallback for when P2P isn't possible.

### The Game view

To make the Combat Chain easy to read, players can enable draggable Tiles to help their opponent understand their attack.
When you add Tiles to the Combat Chain you can move them about from your preview screen and you opponent will see your updates.
You will also see your opponents life and when they are attacking, their Combat Chain effects.

You can click on the title of your opponents card which will then attempt to look up that card and attempt to recognise the card
which will then be displayed in a small modal so that the card can be inspected closer.

The Game view uses Phoenix LiveView to update state across clients and for card recognition.

### Card Recognition

One of the key features of the app is card recognition. A player simply needs to click the title of a card that they see on their opponents screen and it will send data to the backend and display the card from an external image in a moveable modal.

This works a couple ways. First we use OpenCV to attempt to find the bounding box for the card, from there we use predetermined offsets to determine where the card art is.
Then we use a p-hash algorithm to generate a 64 bit fingerprint that we can send to the backend. Additionally we can perform OCR using tesseract.js on the title, 
which we determine using set offsets like we do with the art.
If we can't determine a card bounding box we fallback to OCR around the area that the user clicked.
A LiveView modal is generated using the outputs from the recognition methods based on how similar the p-hash is and then fallback to OCR similarity.

The Card database is loaded with a pre-generated 64 bit p-hash of the card art as well as some information about the Card title so we can perform fuzzy string matching using postgres `similarity` and `dmetaphone`.
The data from this was pulled from the fabtcg api, see `Tabletop.Cards.Importer` for more.
