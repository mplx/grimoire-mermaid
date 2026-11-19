# Diagrams

Each fence below is drawn while the book is built. The site and the EPUB show
the SVG, the printable book the PNG beside it.

```mermaid
flowchart LR
  accTitle: From Markdown to a book
  A[Markdown] --> B{Preprocessors}
  B --> C[Site]
  B --> D[PDF]
  B --> E[EPUB]
```

A fence shown as an example stays code:

````markdown
```mermaid
flowchart LR
  A --> B
```
````
