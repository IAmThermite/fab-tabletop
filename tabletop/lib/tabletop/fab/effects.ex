defmodule Tabletop.Fab.Effects do
  @conditions_map %{
    dominate: %{
      name: "Dominate",
      icon: "",
      description: "",
      card_img_src: ""
    },
    overpower: %{
      name: "Overpower",
      icon: "",
      description: "",
      card_img_src: ""
    }
  }

  @on_hit_effects_map %{
    go_again: %{
      name: "Go Again",
      icon: "",
      description: "",
      card_img_src: ""
    },
    mark: %{
      name: "Mark",
      icon: "",
      description: "",
      card_img_src: ""
    },
    frostbite: %{
      name: "Frostbite",
      icon: "",
      description: "",
      card_img_src: ""
    },
    dominate: %{
      name: "Dominate",
      icon: "",
      description: "",
      card_img_src: ""
    },
    bloodrot_pox: %{
      name: "Bloodrot Pox",
      icon: "",
      description: "",
      card_img_src: ""
    }
  }

  def conditions, do: @conditions_map

  def on_hit_effects, do: @on_hit_effects_map
end
