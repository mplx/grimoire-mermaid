# A build

A chapter one directory down links its pictures with `../`.

```mermaid
sequenceDiagram
  accTitle: A plugin round trip
  Grimoire->>Plugin: request on stdin
  Plugin->>Renderer: diagram on stdin
  Renderer-->>Plugin: SVG and PNG
  Plugin-->>Grimoire: rewritten chapters
```

~~~mermaid
gantt
  accTitle: A release
  dateFormat YYYY-MM-DD
  section Grimoire
  Files feature :a1, 2026-11-01, 10d
  section Plugin
  First release :after a1, 5d
~~~
