import streamDeck from "@elgato/streamdeck";

import { PlayPad } from "./actions/play-pad";
import { SelectDeck } from "./actions/select-deck";
import { StopAll } from "./actions/stop-all";
import { StopPad } from "./actions/stop-pad";

streamDeck.logger.setLevel("info");

streamDeck.actions.registerAction(new PlayPad());
streamDeck.actions.registerAction(new StopAll());
streamDeck.actions.registerAction(new StopPad());
streamDeck.actions.registerAction(new SelectDeck());

streamDeck.connect();
