One-line: Centered modal dialog with a warm scrim, blur, and a gentle spring entrance.

```jsx
<Dialog open={open} title="Leave this relay?" onClose={close}
  footer={<><Button variant="ghost" onClick={close}>Stay</Button><Button variant="secondary" onClick={leave}>Leave</Button></>}>
  Peers relying on you will need to find another link.
</Dialog>
```
Click the scrim or the × to close. Put action Buttons in `footer`.
