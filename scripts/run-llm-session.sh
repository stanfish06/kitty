#!/usr/bin/env bash
pwd > /tmp/kitty-cwd
kitten @ action --self=yes goto_session ~/.config/kitty/sessions/llm.kitty-session
