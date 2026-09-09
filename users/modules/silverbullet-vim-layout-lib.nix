{ lib }:
{ layouts }:
let
  semanticTargets = [
    {
      semantic = "left";
      target = "h";
    }
    {
      semantic = "down";
      target = "j";
    }
    {
      semantic = "up";
      target = "k";
    }
    {
      semantic = "right";
      target = "l";
    }
    {
      semantic = "searchNext";
      target = "n";
    }
    {
      semantic = "searchPrev";
      target = "N";
    }
    {
      semantic = "insert";
      target = "i";
    }
    {
      semantic = "insertLineStart";
      target = "I";
    }
    {
      semantic = "wordEnd";
      target = "e";
    }
    {
      semantic = "WORDend";
      target = "E";
    }
    {
      semantic = "setMark";
      target = "m";
    }
    {
      semantic = "findForward";
      target = "f";
    }
    {
      semantic = "findBackward";
      target = "F";
    }
    {
      semantic = "tillForward";
      target = "t";
    }
    {
      semantic = "tillBackward";
      target = "T";
    }
    {
      semantic = "joinLines";
      target = "J";
    }
  ];

  entries = map (mapping: {
    from = layouts."colemak-dh".${mapping.semantic};
    to = mapping.target;
    inherit (mapping) semantic;
  }) semanticTargets;

  activeEntries = builtins.filter (entry: entry.from != entry.to) entries;
  validEntries = builtins.all (
    entry: builtins.match "[A-Za-z]" entry.from != null && builtins.match "[A-Za-z]" entry.to != null
  ) activeEntries;
  uniqueSources =
    builtins.length activeEntries
    == builtins.length (lib.unique (map (entry: entry.from) activeEntries));
  langmap = lib.concatMapStringsSep "," (entry: "${entry.from}${entry.to}") activeEntries;
in
assert layouts.qwerty.inside == layouts.qwerty.insert;
assert layouts."colemak-dh".inside == layouts."colemak-dh".insert;
assert layouts.qwerty.git == layouts."colemak-dh".git;
assert validEntries;
assert uniqueSources;
{
  inherit activeEntries langmap semanticTargets;
}
