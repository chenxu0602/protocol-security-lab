# Review Checklist

## Money Flow
- How does value enter?
- How does value leave?
- Who can move funds?
- Can one user affect another user's funds?

## Roles / Permissions
- Who is admin?
- Who can pause?
- Who can upgrade?
- Who can change critical params?

## Accounting
- How are balances tracked?
- How are shares minted/burned?
- How are fees accounted for?
- Are there rounding / precision issues?

## External Risk
- Oracle dependencies?
- External calls?
- Token assumptions?
- Reentrancy surfaces?

## State Machine
- What are the main state transitions?
- Are there invalid state combinations?
- Are there edge cases around initialization / shutdown?
