# Overview

moe adopts the mode and keybinding like vi/vim.
You can easily adapt if you have used vi/vim.
Currently you can use normal mode, visual mode, replace mode, insert mode, ex mode, filer mode.

# Install and compile

## Requires
- Nim 1.0 or higher
- ncurses (ncursesw)

I recommend using nimble to install:

```
$ nimble install moe
```

If you want to compile moe or use a version in development:

```
$ git clone https://github.com/fox0430/moe
$ cd moe
$ nimble install
```

If you are running Linux Ubuntu, or a distribution based on Ubuntu, you will likely need to run

```
$ sudo apt install libncurses5-dev libncursesw5-dev
$ nimble install moe
```

Fedora

```
$ sudo dnf install ncurses-devel
$ nimble install moe
```
