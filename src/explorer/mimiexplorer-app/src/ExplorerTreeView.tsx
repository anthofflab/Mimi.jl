import React from 'react';
import { TreeView, TreeItem } from '@material-ui/lab';
import { ExpandMore, ChevronRight } from "@material-ui/icons";

export interface TreeViewProps {
    name: string
}

type TreeNodeState = {
    name: string,
    children: Array<TreeNodeState>
}
  
export default class ExplorerTreeView extends React.Component<TreeViewProps, TreeNodeState> {

    static defaultProps = {
        name: "",
    }

    constructor(props: TreeViewProps) {
        super(props);
        this.state ={
            name: props.name,
            children: new Array<TreeNodeState>()
        }
        global["setTreeChildren"] = this.setTreeChildren;
    }

    setTreeChildren = (childrenInfo:Array<TreeNodeState>) => {
        this.setState({children: childrenInfo});
    }

    renderTree = (node:TreeNodeState) => {
        return (
            <div>
                <TreeItem key={node.name} nodeId={node.name} label={node.name} onLabelClick= {(event)=> {
                    event.preventDefault();
                    global["sendMessageToJulia"]({cmd: 'update_data', comp_name: node.name})
                }}>
                    {node.children ? node.children.map((n) => this.renderTree(n)) : null}
                </TreeItem>
            </div>
        );
    }

    render = () => {
        const renderVal = (<div className="ExplorerTreeView">
            <h4>{this.state.name}</h4>
            <TreeView
                className={"classes.root"}
                defaultCollapseIcon={<ExpandMore />}
                defaultExpanded={["root"]}
                defaultExpandIcon={<ChevronRight />}
            >
                {this.state.children ? this.state.children.map((n) => this.renderTree(n)) : null}
            </TreeView>
        </div>);
        return renderVal;
    };
}

  