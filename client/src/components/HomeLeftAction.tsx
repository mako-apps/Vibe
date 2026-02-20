import React from 'react';
import { Edit3, CheckCheck } from 'lucide-react';
import './HomeLeftAction.css';

interface HomeLeftActionProps {
    isEditing: boolean;
    setIsEditing: (is: boolean) => void;
}

const HomeLeftAction: React.FC<HomeLeftActionProps> = ({ isEditing, setIsEditing }) => {
    return (
        <button
            className="home-left-action"
            onClick={() => setIsEditing(!isEditing)}
            aria-label={isEditing ? "Done editing" : "Edit chats"}
        >
            {isEditing ? (
                <CheckCheck size={12} className="home-left-icon active" />
            ) : (
                <Edit3 size={12} className="home-left-icon" />
            )}
        </button>
    );
};

export default HomeLeftAction;
